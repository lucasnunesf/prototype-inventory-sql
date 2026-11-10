"""
End to end: build the database from the files in sql/, the way the README
says, and check that the numbers it reports are what the database returns.
"""

import psycopg
import pytest

from conftest import run_file


def scalar(db, sql):
    return db.execute(sql).fetchone()[0]


def test_sample_data_loads_through_the_triggers(db):
    """Every one of the 1,980 movements passed the validation triggers."""
    assert scalar(db, "SELECT COUNT(*) FROM parts") == 320
    assert scalar(db, "SELECT COUNT(*) FROM movements") == 1980
    assert scalar(db, "SELECT COUNT(*) FROM inventory_counts") == 144
    assert scalar(db, "SELECT COUNT(*) FROM count_scans") == 1002


def test_rejected_forms_corrected_on_the_spot(db):
    assert scalar(db, """SELECT COUNT(*) FROM movements
                         WHERE notes LIKE 'Form rejected%'""") == 50


def test_count_accuracy_matches_readme(db):
    rows = db.execute("""SELECT count_date::text, matched, missing, unrecorded, accuracy_pct::float
                         FROM v_count_accuracy ORDER BY count_date""").fetchall()
    assert rows == [
        ("2026-04-30", 156, 0, 1, 99.4),
        ("2026-05-29", 148, 1, 5, 96.1),
        ("2026-06-30", 170, 1, 9, 94.4),
        ("2026-07-31", 164, 3, 7, 94.3),
        ("2026-08-31", 165, 4, 9, 92.7),
        ("2026-09-30", 158, 4, 10, 91.9),
    ]


def test_overdue_parts_on_reference_date(db):
    rows = db.execute("""SELECT qr_code, days_overdue FROM fn_parts_outside('2026-09-30')
                         WHERE status = 'OVERDUE' ORDER BY days_overdue DESC""").fetchall()
    assert len(rows) == 20
    assert rows[0] == ("QR-00272", 153)


def test_reconciliation_classifies_every_scan(db):
    """Each count line is MATCH, MISSING or UNRECORDED, and matched plus
    unrecorded add up to the QR codes actually scanned."""
    found = scalar(db, """SELECT COUNT(*) FROM v_count_reconciliation
                          WHERE result IN ('MATCH', 'UNRECORDED')""")
    assert found == scalar(db, "SELECT COUNT(*) FROM count_scans")


def test_analysis_queries_run(built_db):
    with psycopg.connect(dbname=built_db, autocommit=True) as conn:
        run_file(conn, "05_analysis_queries.sql")


def test_sql_rule_checks_pass(built_db):
    """06_rule_checks.sql raises an error if any of its checks fails."""
    with psycopg.connect(dbname=built_db, autocommit=True) as conn:
        run_file(conn, "06_rule_checks.sql")


def test_build_can_be_run_twice(dbname):
    """01_schema.sql drops and recreates the schema, so rebuilding is safe."""
    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        for f in ["01_schema.sql", "02_business_rules.sql", "03_views.sql", "04_sample_data.sql"]:
            run_file(conn, f)
        assert conn.execute("SELECT COUNT(*) FROM inventory.movements").fetchone()[0] == 1980
