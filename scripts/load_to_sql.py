"""
Load the Excel files into a SQL database and export the views for Power BI.

Steps:
  1. Read data/parts.xlsx and data/form_responses.xlsx with pandas.
  2. Clean the part code (upper case, no spaces, always "QR-0000")
     and read the dates as day/month/year.
  3. Create the tables (sql/01_tables.sql) in inventory.db (SQLite)
     and insert the rows.
  4. Create the views (sql/02_views.sql).
  5. Save each view as a CSV in output/ for Power BI.

Run:  python scripts/load_to_sql.py
"""

import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DATA, SQL, OUTPUT = ROOT / "data", ROOT / "sql", ROOT / "output"
DB = ROOT / "inventory.db"

# 1. Read
parts = pd.read_excel(DATA / "parts.xlsx")
forms = pd.read_excel(DATA / "form_responses.xlsx")

# 2. Clean
code = forms["Part code"].str.strip().str.upper().str.replace("-", "")
forms["Part code"] = "QR-" + code.str[2:]
forms["Timestamp"] = pd.to_datetime(forms["Timestamp"], format="%d/%m/%Y %H:%M:%S")

movements = pd.DataFrame({
    "moved_at": forms["Timestamp"].dt.strftime("%Y-%m-%d %H:%M:%S"),
    "moved_by": forms["Name"],
    "part_code": forms["Part code"],
    "from_place": forms["From"],
    "to_place": forms["To"],
    "reason": forms["Reason"],
})

unknown = set(movements["part_code"]) - set(parts["part_code"])
if unknown:
    raise SystemExit(f"Part codes not in the part list: {sorted(unknown)}")

# 3 and 4. Tables, rows and views
with sqlite3.connect(DB) as con:
    con.executescript((SQL / "01_tables.sql").read_text())
    parts.to_sql("parts", con, if_exists="append", index=False)
    movements.to_sql("movements", con, if_exists="append", index=False)
    con.executescript((SQL / "02_views.sql").read_text())

    # 5. Export for Power BI
    OUTPUT.mkdir(exist_ok=True)
    for view in ["v_current_location", "v_movements_by_month", "v_parts_outside"]:
        df = pd.read_sql(f"SELECT * FROM {view}", con)
        df.to_csv(OUTPUT / f"{view.removeprefix('v_')}.csv", index=False)
        print(f"{view}: {len(df)} rows")

print(f"Loaded {len(parts)} parts and {len(movements)} movements into {DB.name}")
