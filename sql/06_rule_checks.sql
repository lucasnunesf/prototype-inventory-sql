-- =============================================================================
-- 06_rule_checks.sql
-- Proves the business rules work: each check tries something the database
-- must reject and confirms that it was rejected for the right reason.
-- Everything runs inside a transaction that is rolled back at the end,
-- so the sample data is not changed.
--
-- Run after 04_sample_data.sql.
-- =============================================================================

SET search_path TO inventory;

BEGIN;

CREATE TEMP TABLE rule_check_results (
    check_name  text,
    passed      boolean,
    detail      text
);

-- Insert a movement using codes instead of ids, like the form would.
CREATE FUNCTION pg_temp.submit_form(
    p_qr text, p_type text, p_from text, p_to text,
    p_at timestamp, p_return date DEFAULT NULL
) RETURNS void
LANGUAGE sql
AS $$
    INSERT INTO inventory.movements
        (part_id, movement_type, from_location_id, to_location_id,
         moved_by, moved_at, expected_return_date)
    SELECT p.part_id, p_type, lf.location_id, lt.location_id,
           (SELECT employee_id FROM inventory.employees WHERE employee_code = 'EMP-12'),
           p_at, p_return
    FROM inventory.parts p
    LEFT JOIN inventory.locations lf ON lf.location_code = p_from
    JOIN inventory.locations      lt ON lt.location_code = p_to
    WHERE p.qr_code = p_qr;
$$;

-- Run a statement that must fail, and check the error message.
CREATE FUNCTION pg_temp.expect_error(p_name text, p_sql text, p_expected text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE p_sql;
    INSERT INTO rule_check_results VALUES (p_name, false, 'Statement succeeded but should have failed');
EXCEPTION WHEN OTHERS THEN
    INSERT INTO rule_check_results
    VALUES (p_name, SQLERRM ILIKE '%' || p_expected || '%', SQLERRM);
END;
$$;

-- QR-00303 ends the sample data on shelf WH-C-02 (last movement 2026-09-08).
-- QR-00317 was scrapped on 2026-06-22.

DO $checks$
BEGIN
    PERFORM pg_temp.expect_error(
        'Rule 1 - part must leave from its recorded location',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'TRANSFER', 'WH-A-01', 'WS-01', '2026-10-01 09:00') $q$,
        'is recorded at WH-C-02');

    PERFORM pg_temp.expect_error(
        'Rule 2 - TRANSFER cannot go to a supplier',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'TRANSFER', 'WH-C-02', 'SUP-01', '2026-10-01 09:00') $q$,
        'TRANSFER must be between internal locations');

    PERFORM pg_temp.expect_error(
        'Rule 2 - SHIPMENT must go outside the site',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'SHIPMENT', 'WH-C-02', 'WS-01', '2026-10-01 09:00', '2026-10-15') $q$,
        'SHIPMENT must go to an external');

    PERFORM pg_temp.expect_error(
        'Rule 3 - SHIPMENT needs an expected return date',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'SHIPMENT', 'WH-C-02', 'SUP-01', '2026-10-01 09:00') $q$,
        'need an expected return date');

    PERFORM pg_temp.expect_error(
        'Rule 3 - return date cannot be before the shipment',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'SHIPMENT', 'WH-C-02', 'SUP-01', '2026-10-01 09:00', '2026-09-20') $q$,
        'chk_return_date_after_movement');

    PERFORM pg_temp.expect_error(
        'Rule 4 - scrapped parts cannot move',
        $q$ SELECT pg_temp.submit_form('QR-00317', 'TRANSFER', 'SCRAP', 'WH-A-01', '2026-10-01 09:00') $q$,
        'has been scrapped');

    PERFORM pg_temp.expect_error(
        'Rule 5 - no back-dating before the last movement',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'TRANSFER', 'WH-C-02', 'WS-01', '2026-09-01 09:00') $q$,
        'is before the last movement');

    PERFORM pg_temp.expect_error(
        'Rule 6 - history cannot be edited',
        $q$ UPDATE inventory.movements SET notes = 'edited' WHERE movement_id = 1 $q$,
        'append-only');

    PERFORM pg_temp.expect_error(
        'Rule 6 - history cannot be deleted',
        $q$ DELETE FROM inventory.movements WHERE movement_id = 1 $q$,
        'append-only');

    PERFORM pg_temp.expect_error(
        'A part cannot be registered twice',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'REGISTRATION', NULL, 'WH-A-01', '2026-10-01 09:00') $q$,
        'already registered');

    PERFORM pg_temp.expect_error(
        'Every movement must change location',
        $q$ SELECT pg_temp.submit_form('QR-00303', 'TRANSFER', 'WH-C-02', 'WH-C-02', '2026-10-01 09:00') $q$,
        'chk_movement_changes_location');

    -- Rule 7 - a valid form goes through and the part moves in the system.
    PERFORM pg_temp.submit_form('QR-00303', 'TRANSFER', 'WH-C-02', 'WS-01', '2026-10-01 09:00');
END;
$checks$;

INSERT INTO rule_check_results
SELECT
    'Rule 7 - a valid form updates the part location',
    l.location_code = 'WS-01',
    'Part is now at ' || l.location_code
FROM parts p
JOIN locations l ON l.location_id = p.current_location_id
WHERE p.qr_code = 'QR-00303';

-- Results.
SELECT check_name, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, detail
FROM rule_check_results;

-- Fail loudly if any check did not pass (used by the GitHub Actions workflow).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM rule_check_results WHERE NOT passed) THEN
        RAISE EXCEPTION 'Some rule checks failed';
    END IF;
END;
$$;

ROLLBACK;
