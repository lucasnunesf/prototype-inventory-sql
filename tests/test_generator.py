"""
Unit tests for the sample data generator (no database needed).
"""

from datetime import date, datetime

import pytest

import generate_sample_data as gen


@pytest.fixture
def run(tmp_path, monkeypatch):
    """Run the simulation from the fixed seed, writing to a temp folder."""
    monkeypatch.setattr(gen, "OUTPUT", tmp_path / "04_sample_data.sql")
    gen.rng.seed(gen.SEED)
    parts, sim = gen.simulate()
    gen.write_sql(parts, sim)
    return parts, sim, gen.OUTPUT


# --- helpers ---------------------------------------------------------------

@pytest.mark.parametrize("value, expected", [
    (None, "NULL"),
    (7, "7"),
    ("O'Brien", "'O''Brien'"),
    (date(2026, 4, 1), "'2026-04-01'"),
    (datetime(2026, 4, 1, 9, 5), "'2026-04-01 09:05'"),
])
def test_sql_literal(value, expected):
    assert gen.q(value) == expected


def test_business_days_skip_weekends():
    days = list(gen.business_days(date(2026, 4, 3), date(2026, 4, 7)))   # Fri to Tue
    assert days == [date(2026, 4, 3), date(2026, 4, 6), date(2026, 4, 7)]


@pytest.mark.parametrize("d, expected", [
    (date(2026, 4, 30), True),    # Thursday, last day of April
    (date(2026, 5, 29), True),    # Friday, May ends on a Sunday
    (date(2026, 5, 28), False),
])
def test_last_business_day_of_month(d, expected):
    assert gen.last_business_day_of_month(d) is expected


def test_reference_data_sizes():
    assert len(gen.CUSTOMERS) == 11
    assert len(gen.PROJECTS) == 17
    assert len(gen.PART_TYPES) == 108
    assert len(gen.SHELVES) == 24


# --- simulation --------------------------------------------------------------

def test_simulation_totals(run):
    parts, sim, _ = run
    assert len(parts) == 320
    assert len(sim.movements) == 1980
    assert sim.rejected_forms == 50
    assert len(sim.counts) == 6 * 24


def test_committed_sample_data_matches_generator(run):
    """sql/04_sample_data.sql is exactly what the script produces."""
    _, _, out = run
    committed = (gen.Path(__file__).resolve().parent.parent / "sql" / "04_sample_data.sql")
    assert out.read_text(encoding="utf-8") == committed.read_text(encoding="utf-8")


def test_every_rejected_form_is_followed_by_the_real_movement(run):
    """The simulation's own version of rule 1: an ADJUSTMENT for a rejected
    form is always followed, 5 minutes later, by the movement itself."""
    _, sim, _ = run
    by_part = {}
    for m in sim.movements:
        by_part.setdefault(m[0], []).append(m)
    for moves in by_part.values():
        for a, b in zip(moves, moves[1:]):
            if a[1] == "ADJUSTMENT" and a[7] and a[7].startswith("Form rejected"):
                assert b[2] == a[3]                       # leaves from the corrected place
                assert (b[5] - a[5]).total_seconds() == 300
