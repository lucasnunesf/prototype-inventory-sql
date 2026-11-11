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


def test_feature_checks_pass(built_db):
    """10_feature_checks.sql covers count closing, the mart and the roles."""
    with psycopg.connect(dbname=built_db, autocommit=True) as conn:
        run_file(conn, "10_feature_checks.sql")


def test_sql_count_closing_matches_the_simulation(db):
    """The count closing rule written in SQL posts exactly the adjustments
    the Python simulation posted, in all six counts."""
    from_sql = db.execute("""
        SELECT a.part_id, a.to_location_id, a.adjusted_at
        FROM (SELECT DISTINCT counted_at FROM inventory_counts) r,
             fn_count_adjustments(r.counted_at) a ORDER BY 1, 3""").fetchall()
    from_python = db.execute("""
        SELECT part_id, to_location_id, moved_at FROM movements
        WHERE notes IN ('Found during monthly count',
                        'Not found in two consecutive counts - written off')
        ORDER BY 1, 3""").fetchall()
    assert len(from_sql) == 42
    assert from_sql == from_python


def test_mart_monthly_kpis(db):
    rows = db.execute("""SELECT month_label, movements, count_accuracy_pct::float,
                                active_parts_month_end, overdue_outside_month_end
                         FROM mart.kpi_monthly ORDER BY month_start""").fetchall()
    assert [r[0] for r in rows] == ["Apr 2026", "May 2026", "Jun 2026",
                                    "Jul 2026", "Aug 2026", "Sep 2026"]
    assert sum(r[1] for r in rows) == 1980
    assert rows[-1][2:] == (91.9, 245, 20)


def test_form_app_cannot_post_an_adjustment(db):
    db.execute("SET LOCAL ROLE inv_form_app")
    with pytest.raises(psycopg.errors.InsufficientPrivilege, match="row-level security"):
        db.execute("""
            INSERT INTO movements (part_id, movement_type, from_location_id,
                                   to_location_id, moved_by, moved_at)
            SELECT part_id, 'ADJUSTMENT', current_location_id, 1, 12, '2026-10-01'
            FROM parts WHERE qr_code = 'QR-00303'""")


def test_build_can_be_run_twice(dbname):
    """01_schema.sql drops and recreates the schema, and 08 the mart, so
    rebuilding is safe. Roles already on the server are reused."""
    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        for f in ["01_schema.sql", "02_business_rules.sql", "03_views.sql", "04_sample_data.sql",
                  "07_count_closing.sql", "08_reporting_mart.sql", "09_access_roles.sql"]:
            run_file(conn, f)
        assert conn.execute("SELECT COUNT(*) FROM inventory.movements").fetchone()[0] == 1980
