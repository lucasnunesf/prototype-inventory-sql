"""
Create the fake input files: the part list and the form responses.

At work, every prototype part had a QR code. Scanning it opened a
Microsoft Forms form, and the answers were exported to Excel.
This script builds two Excel files that look like that:

  data/parts.xlsx           one row per part (code, part type, customer)
  data/form_responses.xlsx  one row per form answer (a part moved)

All names and codes are invented. The random seed is fixed, so the
files are the same every time.

Run:  python scripts/generate_data.py
"""

import random
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd

random.seed(7)
DATA = Path(__file__).resolve().parent.parent / "data"
DATA.mkdir(exist_ok=True)

START = datetime(2026, 4, 1)
END = datetime(2026, 9, 30)

PART_TYPES = ["Steering gear", "Steering column", "Steering pump", "Torque sensor",
              "Electric motor", "Control unit", "Tie rod", "Intermediate shaft"]
CUSTOMERS = [f"Customer {i:02d}" for i in range(1, 11)]
SHELVES = ["Shelf A", "Shelf B", "Shelf C", "Shelf D"]
INSIDE = ["Workshop", "Test lab"]
OUTSIDE = ["Supplier", "Other plant"]
PEOPLE = ["Ana", "Bruno", "Carla", "Diego", "Elisa", "Felipe"]

# 1. Part list
parts = []
for i in range(1, 151):
    parts.append({
        "part_code": f"QR-{i:04d}",
        "part_type": random.choice(PART_TYPES),
        "customer": random.choice(CUSTOMERS),
    })
pd.DataFrame(parts).to_excel(DATA / "parts.xlsx", index=False)

# 2. Form answers: every part arrives on a shelf, then moves around
answers = []


def answer(when, code, origin, destination, reason):
    # Like a real form, the part code is sometimes typed by hand:
    # lower case or with extra spaces. The load script cleans this.
    if random.random() < 0.08:
        code = random.choice([code.lower(), f" {code} ", code.replace("-", "")])
    answers.append({
        "Timestamp": when.strftime("%d/%m/%Y %H:%M:%S"),
        "Name": random.choice(PEOPLE),
        "Part code": code,
        "From": origin,
        "To": destination,
        "Reason": reason,
    })


for p in parts:
    when = START + timedelta(days=random.randint(0, 40), hours=random.randint(7, 16),
                             minutes=random.randint(0, 59))
    place = random.choice(SHELVES)
    answer(when, p["part_code"], "Receiving", place, "New part")

    while True:
        # Parts sent outside take longer to come back
        days = random.randint(15, 60) if place in OUTSIDE else random.randint(3, 25)
        when = (when + timedelta(days=days)).replace(hour=random.randint(7, 16),
                                                     minute=random.randint(0, 59))
        if when > END:
            break
        if place in SHELVES:
            destination = random.choices(INSIDE + OUTSIDE, weights=[45, 30, 15, 10])[0]
            reason = {"Workshop": "Assembly", "Test lab": "Test",
                      "Supplier": "Sent to supplier", "Other plant": "Sent to other plant"}[destination]
        else:
            destination = random.choice(SHELVES)
            reason = "Back to storage"
        answer(when, p["part_code"], place, destination, reason)
        place = destination

answers.sort(key=lambda a: datetime.strptime(a["Timestamp"], "%d/%m/%Y %H:%M:%S"))
pd.DataFrame(answers).to_excel(DATA / "form_responses.xlsx", index=False)

print(f"{len(parts)} parts and {len(answers)} form answers written to {DATA}")
