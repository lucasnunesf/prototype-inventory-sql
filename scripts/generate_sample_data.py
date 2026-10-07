"""
Generate synthetic data for the prototype inventory database.

The script simulates six months of a prototype parts area and writes
sql/04_sample_data.sql. Everything is fictional: customers, projects,
part types, locations and employees are generic codes.

The simulation keeps two versions of where each part is:

  * true_loc   - where the part physically is
  * sys_loc    - where the database says it is

Most movements are recorded through the QR code form, so both stay in sync.
A small share of movements is never recorded (someone takes a part and
forgets the form). That is what creates divergence, which then shows up in
the monthly physical counts and in rejected form submissions.

Usage:
    python scripts/generate_sample_data.py

No third-party packages needed. The random seed is fixed, so the output is
always the same.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

SEED = 42
START = date(2026, 4, 1)
END = date(2026, 9, 30)
N_PARTS = 320
OUTPUT = Path(__file__).resolve().parent.parent / "sql" / "04_sample_data.sql"

# Probability that a movement happens but nobody fills in the form.
UNRECORDED_INTERNAL = 0.07   # shelf <-> workshop/lab, returns from outside
UNRECORDED_SHIPMENT = 0.02   # sending outside usually comes with paperwork
UNRECORDED_SCRAP = 0.10      # part destroyed in test and thrown away

rng = random.Random(SEED)

# -----------------------------------------------------------------------------
# Reference data
# -----------------------------------------------------------------------------

CUSTOMERS = [
    ("CUS-01", "Customer 01 - Heavy trucks"),
    ("CUS-02", "Customer 02 - Medium trucks"),
    ("CUS-03", "Customer 03 - Light commercial"),
    ("CUS-04", "Customer 04 - Buses"),
    ("CUS-05", "Customer 05 - Agricultural machinery"),
    ("CUS-06", "Customer 06 - Construction equipment"),
    ("CUS-07", "Customer 07 - Pickups"),
    ("CUS-08", "Customer 08 - Vans"),
    ("CUS-09", "Customer 09 - Off-road vehicles"),
    ("CUS-10", "Customer 10 - Special vehicles"),
    ("CUS-11", "Customer 11 - Urban delivery trucks"),
]

PROJECTS = []
for i, (code, _) in enumerate(CUSTOMERS):
    n = 2 if i < 6 else 1
    for j in range(1, n + 1):
        PROJECTS.append((code, f"PRJ-{code[-2:]}-{j}", f"Vehicle program {code[-2:]}.{j}"))

FAMILIES = [
    "Steering gear", "Steering column", "Steering pump", "Brake caliper",
    "Brake valve", "ABS module", "Engine control unit", "Wiring harness",
    "Fuel injector", "Pressure sensor", "Speed sensor", "Electric actuator",
]
PART_TYPES = []
for f_idx, family in enumerate(FAMILIES):
    for v in range(1, 10):
        n = f_idx * 9 + v
        PART_TYPES.append((f"PT-{n:03d}", f"{family} - variant {v}"))

SHELVES = [f"WH-{aisle}-{pos:02d}" for aisle in "ABC" for pos in range(1, 9)]
LOCATIONS = (
    [(s, "WAREHOUSE", f"Prototype warehouse, aisle {s[3]}, position {s[-2:]}") for s in SHELVES]
    + [("WS-01", "WORKSHOP", "Prototype workshop 1"),
       ("WS-02", "WORKSHOP", "Prototype workshop 2"),
       ("LAB-01", "TEST_LAB", "Internal test lab")]
    + [(f"PLANT-{i:02d}", "EXTERNAL_PLANT", f"External plant {i:02d}") for i in range(1, 4)]
    + [(f"SUP-{i:02d}", "SUPPLIER", f"Supplier {i:02d}") for i in range(1, 6)]
    + [("SCRAP", "SCRAP", "Scrap area")]
)
LOC_TYPE = {code: typ for code, typ, _ in LOCATIONS}
INTERNAL_WORK = ["WS-01", "WS-02", "LAB-01"]
EXTERNAL = [c for c, t, _ in LOCATIONS if t in ("EXTERNAL_PLANT", "SUPPLIER")]

TEAMS = {
    "Prototype workshop": [f"EMP-{i:02d}" for i in range(1, 6)],
    "Test lab": [f"EMP-{i:02d}" for i in range(6, 9)],
    "Project management": [f"EMP-{i:02d}" for i in range(9, 12)],
    "Logistics": [f"EMP-{i:02d}" for i in range(12, 14)],
}
EMPLOYEES = [(code, team) for team, codes in TEAMS.items() for code in codes]
ALL_EMP = [code for code, _ in EMPLOYEES]


def is_external(loc: str) -> bool:
    return LOC_TYPE[loc] in ("EXTERNAL_PLANT", "SUPPLIER")


# -----------------------------------------------------------------------------
# Simulation state
# -----------------------------------------------------------------------------

@dataclass
class Part:
    qr: str
    part_type: str
    project: str
    registered_on: date
    true_loc: str | None = None
    sys_loc: str | None = None
    scrapped: bool = False          # physically gone
    written_off: bool = False       # system closed it
    return_on: date | None = None   # when it physically comes back from outside
    missed_counts: int = 0


@dataclass
class Sim:
    movements: list = field(default_factory=list)   # rows for the movements table
    counts: list = field(default_factory=list)      # (shelf, counted_at, employee)
    scans: list = field(default_factory=list)       # (shelf, counted_at, qr)
    rejected_forms: int = 0

    def record(self, part, mtype, frm, to, emp, at, exp=None, notes=None):
        self.movements.append((part.qr, mtype, frm, to, emp, at, exp, notes))
        part.sys_loc = to

    def form(self, part: Part, mtype, to, emp, at, exp=None, notes=None):
        """Someone scans the QR code and submits the form for a real movement.

        The form uses the place where the part really is. If the database
        disagrees, the movement is rejected (rule 1), so logistics first
        records an ADJUSTMENT and then the movement goes through.
        """
        if part.sys_loc != part.true_loc:
            self.rejected_forms += 1
            self.record(part, "ADJUSTMENT", part.sys_loc, part.true_loc,
                        rng.choice(TEAMS["Logistics"]), at,
                        notes="Form rejected: part was not at the recorded location")
            at = at + timedelta(minutes=5)
        self.record(part, mtype, part.true_loc, to, emp, at, exp, notes)


def business_days(start: date, end: date):
    d = start
    while d <= end:
        if d.weekday() < 5:
            yield d
        d += timedelta(days=1)


def at_time(d: date, h0=7, h1=15) -> datetime:
    minutes = rng.randint(h0 * 60, h1 * 60 + 30)
    return datetime(d.year, d.month, d.day, minutes // 60, minutes % 60)


def last_business_day_of_month(d: date) -> bool:
    nxt = d + timedelta(days=1)
    while nxt.weekday() >= 5:
        nxt += timedelta(days=1)
    return nxt.month != d.month


def simulate() -> tuple[list[Part], Sim]:
    days = list(business_days(START, END))

    # Most parts arrive in the first weeks of the period, the rest over time.
    parts = []
    for i in range(1, N_PARTS + 1):
        if rng.random() < 0.6:
            reg = rng.choice(days[:22])
        else:
            reg = rng.choice(days[22:110])
        project = rng.choice(PROJECTS)[1]
        parts.append(Part(f"QR-{i:05d}", rng.choice(PART_TYPES)[0], project, reg))

    sim = Sim()

    for d in days:
        todays = []
        for p in parts:
            if p.registered_on == d:
                todays.append(("REG", p))
            elif p.true_loc is not None and not p.scrapped:
                todays.append(("MOVE", p))

        rng.shuffle(todays)
        stamps = sorted(at_time(d) for _ in todays)

        for (kind, p), at in zip(todays, stamps):
            emp_wh = rng.choice(TEAMS["Logistics"] + TEAMS["Project management"])

            if kind == "REG":
                shelf = rng.choice(SHELVES)
                p.true_loc = shelf
                sim.record(p, "REGISTRATION", None, shelf, emp_wh, at,
                           notes="Received from customer")
                continue

            loc = p.true_loc
            ltype = LOC_TYPE[loc]

            if ltype == "WAREHOUSE":
                if rng.random() > 0.045:
                    continue
                r = rng.random()
                if r < 0.55:
                    dest, mtype = rng.choice(["WS-01", "WS-02"]), "TRANSFER"
                    emp = rng.choice(TEAMS["Prototype workshop"])
                elif r < 0.75:
                    dest, mtype, emp = "LAB-01", "TRANSFER", rng.choice(TEAMS["Test lab"])
                elif r < 0.82:
                    dest = rng.choice([s for s in SHELVES if s != loc])
                    mtype, emp = "TRANSFER", emp_wh
                else:
                    dest, mtype = rng.choice(EXTERNAL), "SHIPMENT"
                    emp = rng.choice(TEAMS["Project management"])

                if mtype == "SHIPMENT":
                    planned = rng.randint(7, 28)
                    exp = d + timedelta(days=planned)
                    # Some parts never come back; others come back late.
                    if rng.random() < 0.10:
                        p.return_on = None
                    else:
                        delay = rng.randint(-3, 0) if rng.random() < 0.6 else rng.randint(1, 25)
                        p.return_on = exp + timedelta(days=delay)
                    p_unrec = UNRECORDED_SHIPMENT
                    note = "Sent for validation"
                else:
                    exp, p_unrec, note = None, UNRECORDED_INTERNAL, None

                if rng.random() < p_unrec:
                    p.true_loc = dest               # moved, but no form
                else:
                    sim.form(p, mtype, dest, emp, at, exp, note)
                    p.true_loc = dest

            elif ltype in ("WORKSHOP", "TEST_LAB"):
                if rng.random() > 0.22:
                    continue
                emp = rng.choice(TEAMS["Test lab"] if ltype == "TEST_LAB"
                                 else TEAMS["Prototype workshop"])
                if rng.random() < 0.12:
                    # Destroyed during test.
                    if rng.random() < UNRECORDED_SCRAP:
                        p.true_loc, p.scrapped = None, True
                    else:
                        sim.form(p, "SCRAP", "SCRAP", emp, at, notes="Consumed in test")
                        p.true_loc, p.scrapped = "SCRAP", True
                else:
                    dest = rng.choice(SHELVES)
                    if rng.random() < UNRECORDED_INTERNAL:
                        p.true_loc = dest
                    else:
                        sim.form(p, "TRANSFER", dest, emp, at)
                        p.true_loc = dest

            elif is_external(loc):
                if p.return_on is None or d < p.return_on:
                    continue
                dest = rng.choice(SHELVES)
                p.return_on = None
                if rng.random() < UNRECORDED_INTERNAL:
                    p.true_loc = dest
                else:
                    sim.form(p, "RETURN", dest, emp_wh, at, notes="Returned from validation")
                    p.true_loc = dest

        if last_business_day_of_month(d):
            run_monthly_count(d, parts, sim)

    return parts, sim


def run_monthly_count(d: date, parts: list[Part], sim: Sim) -> None:
    """Count every shelf, then correct the system with what was found."""
    counted_at = datetime(d.year, d.month, d.day, 16, 0)
    counter = TEAMS["Logistics"][0]

    found_on = {}
    for shelf in SHELVES:
        sim.counts.append((shelf, counted_at, counter))
        for p in parts:
            if p.true_loc == shelf and not p.scrapped:
                sim.scans.append((shelf, counted_at, p.qr))
                found_on[p.qr] = shelf

    adj_at = datetime(d.year, d.month, d.day, 17, 0)
    for p in parts:
        if p.sys_loc is None or p.written_off:
            continue
        on_shelf_in_system = LOC_TYPE[p.sys_loc] == "WAREHOUSE"

        if p.qr in found_on:
            p.missed_counts = 0
            if p.sys_loc != found_on[p.qr]:
                sim.record(p, "ADJUSTMENT", p.sys_loc, found_on[p.qr], counter, adj_at,
                           notes="Found during monthly count")
                adj_at += timedelta(minutes=1)
        elif on_shelf_in_system:
            p.missed_counts += 1
            # Not found in two counts in a row: written off as lost.
            if p.missed_counts >= 2:
                sim.record(p, "ADJUSTMENT", p.sys_loc, "SCRAP", counter, adj_at,
                           notes="Not found in two consecutive counts - written off")
                p.written_off = True
                p.scrapped = True       # treated as lost from now on
                adj_at += timedelta(minutes=1)


# -----------------------------------------------------------------------------
# SQL output
# -----------------------------------------------------------------------------

def q(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, datetime):
        return f"'{v:%Y-%m-%d %H:%M}'"
    if isinstance(v, date):
        return f"'{v:%Y-%m-%d}'"
    return "'" + str(v).replace("'", "''") + "'"


def values(rows, indent="    ") -> str:
    return ",\n".join(indent + "(" + ", ".join(q(v) for v in r) + ")" for r in rows)


def chunks(rows, size):
    for i in range(0, len(rows), size):
        yield rows[i:i + size]


def write_sql(parts: list[Part], sim: Sim) -> None:
    out = []
    out.append("-- =============================================================================")
    out.append("-- 04_sample_data.sql")
    out.append("-- GENERATED by scripts/generate_sample_data.py - do not edit by hand.")
    out.append(f"-- Synthetic data: {len(parts)} parts, {len(sim.movements)} movements,")
    out.append(f"-- {len(sim.counts)} shelf counts, {START} to {END}.")
    out.append("-- =============================================================================")
    out.append("")
    out.append("SET search_path TO inventory;")
    out.append("")

    out.append("INSERT INTO customers (customer_code, customer_name) VALUES")
    out.append(values(CUSTOMERS) + ";\n")

    out.append("INSERT INTO projects (customer_id, project_code, project_name)")
    out.append("SELECT c.customer_id, v.project_code, v.project_name")
    out.append("FROM (VALUES")
    out.append(values(PROJECTS))
    out.append(") AS v (customer_code, project_code, project_name)")
    out.append("JOIN customers c ON c.customer_code = v.customer_code;\n")

    out.append("INSERT INTO part_types (part_type_code, description) VALUES")
    out.append(values(PART_TYPES) + ";\n")

    out.append("INSERT INTO locations (location_code, location_type, description) VALUES")
    out.append(values(LOCATIONS) + ";\n")

    out.append("INSERT INTO employees (employee_code, team) VALUES")
    out.append(values(EMPLOYEES) + ";\n")

    out.append("INSERT INTO parts (qr_code, part_type_id, project_id)")
    out.append("SELECT v.qr_code, pt.part_type_id, pr.project_id")
    out.append("FROM (VALUES")
    out.append(values([(p.qr, p.part_type, p.project) for p in parts]))
    out.append(") AS v (qr_code, part_type_code, project_code)")
    out.append("JOIN part_types pt ON pt.part_type_code = v.part_type_code")
    out.append("JOIN projects   pr ON pr.project_code   = v.project_code;\n")

    # Movements go in chronological order so the triggers see each part's
    # history exactly as it happened.
    ordered = sorted(enumerate(sim.movements), key=lambda x: (x[1][5], x[0]))
    rows = [(seq, *m) for seq, (_, m) in enumerate(ordered, start=1)]

    out.append("-- Movements are inserted in chronological order (ORDER BY v.seq),")
    out.append("-- so every row passes through the validation triggers.")
    for batch in chunks(rows, 500):
        out.append("INSERT INTO movements (part_id, movement_type, from_location_id, to_location_id,")
        out.append("                       moved_by, moved_at, expected_return_date, notes)")
        out.append("SELECT p.part_id, v.movement_type, lf.location_id, lt.location_id,")
        out.append("       e.employee_id, v.moved_at::timestamp, v.expected_return_date::date, v.notes")
        out.append("FROM (VALUES")
        out.append(values(batch))
        out.append(") AS v (seq, qr_code, movement_type, from_code, to_code, employee_code,")
        out.append("        moved_at, expected_return_date, notes)")
        out.append("JOIN parts          p  ON p.qr_code        = v.qr_code")
        out.append("LEFT JOIN locations lf ON lf.location_code = v.from_code")
        out.append("JOIN locations      lt ON lt.location_code = v.to_code")
        out.append("JOIN employees      e  ON e.employee_code  = v.employee_code")
        out.append("ORDER BY v.seq;\n")

    out.append("INSERT INTO inventory_counts (location_id, counted_at, counted_by)")
    out.append("SELECT l.location_id, v.counted_at::timestamp, e.employee_id")
    out.append("FROM (VALUES")
    out.append(values(sim.counts))
    out.append(") AS v (location_code, counted_at, employee_code)")
    out.append("JOIN locations l ON l.location_code = v.location_code")
    out.append("JOIN employees e ON e.employee_code = v.employee_code;\n")

    out.append("INSERT INTO count_scans (count_id, part_id)")
    out.append("SELECT ic.count_id, p.part_id")
    out.append("FROM (VALUES")
    out.append(values(sim.scans))
    out.append(") AS v (location_code, counted_at, qr_code)")
    out.append("JOIN locations        l  ON l.location_code = v.location_code")
    out.append("JOIN inventory_counts ic ON ic.location_id  = l.location_id")
    out.append("                        AND ic.counted_at   = v.counted_at::timestamp")
    out.append("JOIN parts            p  ON p.qr_code       = v.qr_code;")

    OUTPUT.write_text("\n".join(out) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parts, sim = simulate()
    write_sql(parts, sim)
    print(f"Wrote {OUTPUT}")
    print(f"  parts:          {len(parts)}")
    print(f"  movements:      {len(sim.movements)}")
    print(f"  rejected forms: {sim.rejected_forms}")
    print(f"  shelf counts:   {len(sim.counts)}")
    print(f"  scans:          {len(sim.scans)}")
