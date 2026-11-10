"""
Shared fixtures.

The tests need a PostgreSQL 16 server. Connection settings come from the
usual PG* environment variables (PGHOST, PGUSER, PGPASSWORD...), the same
ones psql uses. A throwaway database is created for the test run and
dropped at the end, so nothing you already have is touched.
"""

from __future__ import annotations

import os
import sys
import uuid
from pathlib import Path

import psycopg
import pytest

ROOT = Path(__file__).resolve().parent.parent
SQL = ROOT / "sql"
BUILD_FILES = ["01_schema.sql", "02_business_rules.sql", "03_views.sql", "04_sample_data.sql"]

# Make scripts/ importable (generate_sample_data.py).
sys.path.insert(0, str(ROOT / "scripts"))


def run_file(conn: psycopg.Connection, name: str) -> None:
    conn.execute((SQL / name).read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def dbname():
    """Create an empty test database, drop it when the run ends."""
    name = f"inventory_test_{uuid.uuid4().hex[:8]}"
    admin_db = os.environ.get("PGDATABASE", "postgres")
    with psycopg.connect(dbname=admin_db, autocommit=True) as admin:
        admin.execute(f'CREATE DATABASE "{name}"')
    yield name
    with psycopg.connect(dbname=admin_db, autocommit=True) as admin:
        admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture(scope="session")
def built_db(dbname):
    """Build schema, rules, views and sample data once, like the README says."""
    with psycopg.connect(dbname=dbname, autocommit=True) as conn:
        for f in BUILD_FILES:
            run_file(conn, f)
    return dbname


@pytest.fixture
def db(built_db):
    """A connection inside a transaction that is rolled back after each test,
    so every test starts from the same sample data."""
    with psycopg.connect(dbname=built_db) as conn:
        conn.execute("SET search_path TO inventory")
        yield conn
        conn.rollback()


def submit_form(conn, qr, mtype, frm, to, at, expected_return=None, notes=None):
    """Insert a movement using codes, the way the QR code form does."""
    conn.execute(
        """
        INSERT INTO movements (part_id, movement_type, from_location_id, to_location_id,
                               moved_by, moved_at, expected_return_date, notes)
        SELECT p.part_id, %s, lf.location_id, lt.location_id,
               (SELECT employee_id FROM employees WHERE employee_code = 'EMP-12'),
               %s, %s, %s
        FROM parts p
        LEFT JOIN locations lf ON lf.location_code = %s
        JOIN locations      lt ON lt.location_code = %s
        WHERE p.qr_code = %s
        """,
        (mtype, at, expected_return, notes, frm, to, qr),
    )


def location_of(conn, qr):
    return conn.execute(
        """SELECT l.location_code FROM parts p
           JOIN locations l ON l.location_id = p.current_location_id
           WHERE p.qr_code = %s""",
        (qr,),
    ).fetchone()[0]
