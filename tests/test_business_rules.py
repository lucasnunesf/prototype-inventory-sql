"""
Business rules, one test per rule.

Each test submits a form the way a person would and checks that the
database refuses it for the right reason, or accepts it and moves the part.

Parts used from the sample data (state on 2026-09-30):
  QR-00303  on shelf WH-C-02, last movement 2026-09-08
  QR-00247  in workshop WS-01
  QR-00272  at supplier SUP-03, 153 days overdue
  QR-00317  scrapped with a form on 2026-06-22
  QR-00022  written off as lost after two counts (2026-06-30)
"""

import psycopg
import pytest

from conftest import location_of, submit_form

AFTER_DATA = "2026-10-01 09:00"


# --- Rule 1: a part can only leave from where the system says it is ----------

def test_rule1_rejects_form_from_wrong_location(db):
    with pytest.raises(psycopg.errors.RaiseException, match="recorded at WH-C-02, not at WH-A-01"):
        submit_form(db, "QR-00303", "TRANSFER", "WH-A-01", "WS-01", AFTER_DATA)


def test_rule1_adjustment_then_form_goes_through(db):
    """What logistics does after a rejected form: fix the record, then move."""
    submit_form(db, "QR-00303", "ADJUSTMENT", "WH-C-02", "WH-A-01", AFTER_DATA,
                notes="Form rejected: part was not at the recorded location")
    submit_form(db, "QR-00303", "TRANSFER", "WH-A-01", "WS-01", "2026-10-01 09:05")
    assert location_of(db, "QR-00303") == "WS-01"


# --- Rule 2: movement type must match the route ------------------------------

@pytest.mark.parametrize("qr, mtype, frm, to, ret, message", [
    ("QR-00303", "TRANSFER", "WH-C-02", "SUP-01", None, "TRANSFER must be between internal"),
    ("QR-00303", "TRANSFER", "WH-C-02", "SCRAP", None, "TRANSFER must be between internal"),
    ("QR-00303", "SHIPMENT", "WH-C-02", "WS-01", "2026-10-15", "SHIPMENT must go to an external"),
    ("QR-00303", "RETURN", "WH-C-02", "WH-A-01", None, "RETURN must come from an external"),
    ("QR-00272", "RETURN", "SUP-03", "PLANT-01", None, "RETURN must come from an external"),
    ("QR-00303", "SCRAP", "WH-C-02", "WS-01", None, "SCRAP movement must go to the scrap area"),
])
def test_rule2_rejects_type_that_does_not_match_route(db, qr, mtype, frm, to, ret, message):
    with pytest.raises(psycopg.errors.RaiseException, match=message):
        submit_form(db, qr, mtype, frm, to, AFTER_DATA, ret)


@pytest.mark.parametrize("qr, mtype, frm, to, ret, end", [
    ("QR-00303", "TRANSFER", "WH-C-02", "LAB-01", None, "LAB-01"),
    ("QR-00303", "SHIPMENT", "WH-C-02", "PLANT-02", "2026-10-20", "PLANT-02"),
    ("QR-00272", "RETURN", "SUP-03", "WH-B-01", None, "WH-B-01"),
    ("QR-00247", "SCRAP", "WS-01", "SCRAP", None, "SCRAP"),
])
def test_rule2_accepts_each_valid_route(db, qr, mtype, frm, to, ret, end):
    submit_form(db, qr, mtype, frm, to, AFTER_DATA, ret)
    assert location_of(db, qr) == end


# --- Rule 3: parts sent outside need a return date ---------------------------

def test_rule3_shipment_without_return_date(db):
    with pytest.raises(psycopg.errors.RaiseException, match="need an expected return date"):
        submit_form(db, "QR-00303", "SHIPMENT", "WH-C-02", "SUP-01", AFTER_DATA)


def test_rule3_return_date_before_shipment(db):
    with pytest.raises(psycopg.errors.CheckViolation, match="chk_return_date_after_movement"):
        submit_form(db, "QR-00303", "SHIPMENT", "WH-C-02", "SUP-01", AFTER_DATA, "2026-09-20")


# --- Rule 4: scrapped parts cannot move again --------------------------------

def test_rule4_scrapped_part_cannot_be_transferred(db):
    with pytest.raises(psycopg.errors.RaiseException, match="has been scrapped"):
        submit_form(db, "QR-00317", "TRANSFER", "SCRAP", "WH-A-01", AFTER_DATA)


def test_rule4_written_off_part_can_be_brought_back_by_adjustment(db):
    """A part written off as lost turns up on a shelf at the next count.
    The record must be correctable, otherwise the database keeps showing
    it as scrapped while it sits on the shelf."""
    assert location_of(db, "QR-00022") == "SCRAP"
    submit_form(db, "QR-00022", "ADJUSTMENT", "SCRAP", "WH-B-04", AFTER_DATA,
                notes="Found during monthly count")
    assert location_of(db, "QR-00022") == "WH-B-04"


# --- Rule 5: no back-dating --------------------------------------------------

def test_rule5_rejects_date_before_last_movement(db):
    with pytest.raises(psycopg.errors.RaiseException, match="is before the last movement"):
        submit_form(db, "QR-00303", "TRANSFER", "WH-C-02", "WS-01", "2026-09-01 09:00")


# --- Rule 6: the history is append-only --------------------------------------

@pytest.mark.parametrize("sql", [
    "UPDATE movements SET notes = 'edited' WHERE movement_id = 1",
    "DELETE FROM movements WHERE movement_id = 1",
])
def test_rule6_history_cannot_be_changed(db, sql):
    with pytest.raises(psycopg.errors.RaiseException, match="append-only"):
        db.execute(sql)


# --- Rule 7: current location always comes from the movements ----------------

def test_rule7_current_location_matches_last_movement_for_every_part(db):
    """For all 320 parts, parts.current_location_id equals the destination
    of the part's last movement."""
    mismatches = db.execute("""
        SELECT COUNT(*) FROM parts p
        WHERE p.current_location_id IS DISTINCT FROM
              fn_location_at(p.part_id, 'infinity'::timestamp)
    """).fetchone()[0]
    assert mismatches == 0


# --- Other guards -------------------------------------------------------------

def test_part_cannot_be_registered_twice(db):
    with pytest.raises(psycopg.errors.RaiseException, match="already registered"):
        submit_form(db, "QR-00303", "REGISTRATION", None, "WH-A-01", AFTER_DATA)


def test_movement_must_change_location(db):
    with pytest.raises(psycopg.errors.CheckViolation, match="chk_movement_changes_location"):
        submit_form(db, "QR-00303", "TRANSFER", "WH-C-02", "WH-C-02", AFTER_DATA)
