-- =============================================================================
-- 10_feature_checks.sql
-- Proves that 07 (count closing), 08 (reporting mart) and 09 (roles) work.
-- Like 06_rule_checks.sql, everything runs in a transaction that is rolled
-- back at the end, and the script fails if any check fails.
--
-- Run after 09_access_roles.sql.
-- =============================================================================

SET search_path TO inventory;

BEGIN;

CREATE TEMP TABLE feature_check_results (
    area        text,
    check_name  text,
    passed      boolean,
    detail      text
);

-- Run a statement as a role.
--   p_expected NULL      the statement must succeed (its effect is undone)
--   p_expected 'text'    it must fail with an error containing that text
CREATE PROCEDURE pg_temp.try_as(
    p_area text, p_name text, p_role text, p_sql text, p_expected text
)
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        IF p_role IS NOT NULL THEN
            EXECUTE format('SET LOCAL ROLE %I', p_role);
        END IF;
        EXECUTE p_sql;
        RAISE EXCEPTION 'statement succeeded';      -- undoes the statement
    EXCEPTION WHEN OTHERS THEN
        -- The role switch is undone together with the statement.
        IF p_expected IS NULL THEN
            INSERT INTO feature_check_results VALUES (p_area, p_name,
                SQLERRM = 'statement succeeded',
                CASE WHEN SQLERRM = 'statement succeeded' THEN 'Allowed' ELSE SQLERRM END);
        ELSE
            INSERT INTO feature_check_results VALUES (p_area, p_name,
                SQLERRM ILIKE '%' || p_expected || '%',
                CASE WHEN SQLERRM = 'statement succeeded'
                     THEN 'Statement succeeded but should have failed' ELSE SQLERRM END);
        END IF;
    END;
END;
$$;

-- =============================================================================
-- 08 Reporting mart: the numbers match the operational views.
-- (Checked first, before anything below adds movements.)
-- =============================================================================

INSERT INTO feature_check_results
SELECT '08 mart', 'fact_movement has every movement',
    (SELECT COUNT(*) FROM mart.fact_movement) = (SELECT COUNT(*) FROM movements),
    (SELECT COUNT(*) FROM mart.fact_movement)::text || ' rows';

INSERT INTO feature_check_results
SELECT '08 mart', 'daily stock on 30 Sep = current stock',
    s.on_hand = c.active,
    s.on_hand || ' parts on hand, v_current_stock has ' || c.active
FROM (SELECT SUM(fs.parts_on_hand) AS on_hand
      FROM mart.fact_daily_stock fs
      JOIN mart.dim_location l ON l.location_key = fs.location_key
      WHERE fs.date_key = 20260930 AND l.location_type <> 'SCRAP') s,
     (SELECT COUNT(*) AS active FROM v_current_stock) c;

INSERT INTO feature_check_results
SELECT '08 mart', 'overdue parts in Sep KPI = fn_parts_outside',
    k.overdue_outside_month_end = f.overdue,
    k.overdue_outside_month_end || ' overdue'
FROM mart.kpi_monthly k,
     (SELECT COUNT(*) AS overdue FROM fn_parts_outside('2026-09-30')
      WHERE status = 'OVERDUE') f
WHERE k.month_start = '2026-09-01';

INSERT INTO feature_check_results
SELECT '08 mart', 'count accuracy carried into the KPIs',
    COUNT(*) = 6 AND bool_and(k.count_accuracy_pct = a.accuracy_pct),
    COUNT(*) || ' months matched'
FROM mart.kpi_monthly k
JOIN v_count_accuracy a ON date_trunc('month', a.count_date) = k.month_start;

INSERT INTO feature_check_results
SELECT '08 mart', 'count day = last business day of each month',
    bool_and(d.full_date = ic.count_date),
    string_agg(to_char(d.full_date, 'DD Mon'), ', ' ORDER BY d.full_date)
FROM mart.dim_date d
JOIN (SELECT DISTINCT counted_at::date AS count_date FROM inventory_counts) ic
  ON date_trunc('month', ic.count_date) = d.month_start
WHERE d.is_count_day;

-- =============================================================================
-- 07 Count closing: the SQL rule gives the same result as the simulation.
-- =============================================================================

WITH rounds AS (SELECT DISTINCT counted_at FROM inventory_counts),
from_sql AS (
    SELECT a.part_id, a.from_location_id, a.to_location_id, a.adjusted_at, a.reason
    FROM rounds r, fn_count_adjustments(r.counted_at) a
),
from_simulation AS (
    SELECT part_id, from_location_id, to_location_id, moved_at, notes
    FROM movements
    WHERE movement_type = 'ADJUSTMENT'
      AND notes IN ('Found during monthly count',
                    'Not found in two consecutive counts - written off')
)
INSERT INTO feature_check_results
SELECT '07 count closing', 'SQL rule = simulation, all 6 counts',
    NOT EXISTS (SELECT * FROM from_sql EXCEPT SELECT * FROM from_simulation)
    AND NOT EXISTS (SELECT * FROM from_simulation EXCEPT SELECT * FROM from_sql),
    (SELECT COUNT(*) FROM from_sql) || ' adjustments, same parts, places and times';

CALL pg_temp.try_as('07 count closing', 'a round cannot be closed twice', NULL,
    $q$ CALL sp_close_count_round('2026-09-30 16:00', 'EMP-12') $q$,
    'already closed');

-- Only one of the 24 shelves counted on 27 Nov.
INSERT INTO inventory_counts (location_id, counted_at, counted_by)
SELECT location_id, '2026-11-27 16:00', 12 FROM locations WHERE location_code = 'WH-A-01';

CALL pg_temp.try_as('07 count closing', 'an incomplete round cannot be closed', NULL,
    $q$ CALL sp_close_count_round('2026-11-27 16:00', 'EMP-12') $q$,
    '23 shelves not counted');

-- A new round on 30 Oct. Every shelf is counted and every part is where the
-- system says, except two:
--   * QR-00303 (system: WH-C-02) is found on WH-A-01
--   * one part already missing on 30 Sep is missing again
CREATE TEMP TABLE oct_case AS
SELECT
    (SELECT p.part_id FROM parts p WHERE p.qr_code = 'QR-00303')        AS moved_part,
    (SELECT p.part_id
     FROM v_count_reconciliation rc
     JOIN parts p      ON p.qr_code = rc.qr_code
     JOIN locations l  ON l.location_id = p.current_location_id
     WHERE rc.counted_at = '2026-09-30 16:00' AND rc.result = 'MISSING'
       AND l.location_type = 'WAREHOUSE'
       -- not found on another shelf in the same round either
       AND NOT EXISTS (SELECT 1 FROM v_count_reconciliation u
                       WHERE u.counted_at = rc.counted_at AND u.qr_code = rc.qr_code
                         AND u.result = 'UNRECORDED')
     ORDER BY p.part_id LIMIT 1)                                        AS missing_part;

INSERT INTO inventory_counts (location_id, counted_at, counted_by)
SELECT location_id, '2026-10-30 16:00', 12
FROM locations WHERE location_type = 'WAREHOUSE';

INSERT INTO count_scans (count_id, part_id)
SELECT ic.count_id, p.part_id
FROM parts p
CROSS JOIN oct_case oc
JOIN inventory_counts ic
  ON ic.counted_at = '2026-10-30 16:00'
 AND ic.location_id = CASE WHEN p.part_id = oc.moved_part
                           THEN (SELECT location_id FROM locations WHERE location_code = 'WH-A-01')
                           ELSE p.current_location_id END
WHERE p.part_id <> oc.missing_part;

CALL sp_close_count_round('2026-10-30 16:00', 'EMP-12');

INSERT INTO feature_check_results
SELECT '07 count closing', 'new round posts exactly the 2 corrections',
    c.adjustments = 2, c.adjustments || ' adjustments registered in count_round_closures'
FROM count_round_closures c WHERE c.counted_at = '2026-10-30 16:00';

INSERT INTO feature_check_results
SELECT '07 count closing', 'part found elsewhere is moved to where it was found',
    l.location_code = 'WH-A-01', 'QR-00303 is now at ' || l.location_code
FROM parts p JOIN locations l ON l.location_id = p.current_location_id
WHERE p.qr_code = 'QR-00303';

INSERT INTO feature_check_results
SELECT '07 count closing', 'part missing twice in a row is written off',
    l.location_code = 'SCRAP', p.qr_code || ' is now at ' || l.location_code
FROM parts p
JOIN oct_case oc ON oc.missing_part = p.part_id
JOIN locations l ON l.location_id = p.current_location_id;

-- =============================================================================
-- 09 Roles: each role can do its job and nothing more.
-- =============================================================================

CALL pg_temp.try_as('09 roles', 'form app can submit a TRANSFER', 'inv_form_app',
    $q$ INSERT INTO movements (part_id, movement_type, from_location_id, to_location_id, moved_by, moved_at)
        SELECT p.part_id, 'TRANSFER', p.current_location_id, l.location_id, 12, '2026-11-02 09:00'
        FROM parts p, locations l WHERE p.qr_code = 'QR-00303' AND l.location_code = 'WS-01' $q$,
    NULL);

CALL pg_temp.try_as('09 roles', 'form app cannot post an ADJUSTMENT', 'inv_form_app',
    $q$ INSERT INTO movements (part_id, movement_type, from_location_id, to_location_id, moved_by, moved_at)
        SELECT p.part_id, 'ADJUSTMENT', p.current_location_id, l.location_id, 12, '2026-11-02 09:00'
        FROM parts p, locations l WHERE p.qr_code = 'QR-00303' AND l.location_code = 'WH-B-01' $q$,
    'row-level security');

CALL pg_temp.try_as('09 roles', 'form app cannot write a location directly', 'inv_form_app',
    $q$ UPDATE parts SET current_location_id = 1 WHERE qr_code = 'QR-00303' $q$,
    'permission denied for table parts');

CALL pg_temp.try_as('09 roles', 'logistics can post an ADJUSTMENT', 'inv_logistics',
    $q$ INSERT INTO movements (part_id, movement_type, from_location_id, to_location_id, moved_by, moved_at)
        SELECT p.part_id, 'ADJUSTMENT', p.current_location_id, l.location_id, 12, '2026-11-02 09:00'
        FROM parts p, locations l WHERE p.qr_code = 'QR-00303' AND l.location_code = 'WH-B-01' $q$,
    NULL);

CALL pg_temp.try_as('09 roles', 'nobody can edit the history, not even logistics', 'inv_logistics',
    $q$ UPDATE movements SET notes = 'edited' WHERE movement_id = 1 $q$,
    'permission denied');

CALL pg_temp.try_as('09 roles', 'Power BI can read the mart', 'inv_bi_reader',
    $q$ SELECT 1 FROM mart.kpi_monthly $q$,
    NULL);

CALL pg_temp.try_as('09 roles', 'Power BI cannot read the operational tables', 'inv_bi_reader',
    $q$ SELECT 1 FROM inventory.parts $q$,
    'permission denied for schema inventory');

-- Results.
SELECT area, check_name, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result, detail
FROM feature_check_results;

-- Fail loudly if any check did not pass (used by the GitHub Actions workflow).
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM feature_check_results WHERE NOT passed) THEN
        RAISE EXCEPTION 'Some feature checks failed';
    END IF;
END;
$$;

ROLLBACK;
