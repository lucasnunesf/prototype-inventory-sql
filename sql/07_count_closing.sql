-- =============================================================================
-- 07_count_closing.sql
-- Closing a monthly count inside the database.
--
-- After every shelf has been counted, logistics corrects the records:
--
--   * a part found on a shelf where the system did not have it
--       -> ADJUSTMENT from where the system had it to where it was found
--   * a part the system had on a shelf, not found in two counts in a row
--       -> ADJUSTMENT to SCRAP (written off as lost)
--
-- In the sample data these corrections are written by the Python simulation.
-- Here the same rule is written once in SQL, so the database can close any
-- future count by itself. fn_count_adjustments() is checked against the six
-- historical counts in 10_feature_checks.sql: same parts, same moves, same
-- times.
--
-- Run after 04_sample_data.sql.
-- =============================================================================

SET search_path TO inventory;

-- One row per count round that has been closed. Rounds already in the
-- sample data are registered as closed at the end of this file.
CREATE TABLE IF NOT EXISTS count_round_closures (
    counted_at      timestamp   PRIMARY KEY,
    closed_by       smallint    NOT NULL REFERENCES employees (employee_id),
    closed_at       timestamp   NOT NULL DEFAULT now(),
    adjustments     integer     NOT NULL
);

-- -----------------------------------------------------------------------------
-- The corrections a count round calls for, computed from what the system
-- knew at the moment of the count. Read-only: nothing is written.
--
-- "Two counts in a row" follows the counting rule on the floor: a round only
-- counts for a part when the system had it on a shelf or the part was found.
-- Rounds where the part was legitimately in the workshop or outside are
-- skipped, they neither reset nor add to its misses.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_count_adjustments(p_counted_at timestamp)
RETURNS TABLE (
    part_id           integer,
    from_location_id  smallint,
    to_location_id    smallint,
    adjusted_at       timestamp,
    reason            text
)
LANGUAGE sql
STABLE
AS $$
    WITH rounds AS (
        -- Every count round up to the one being closed.
        SELECT DISTINCT ic.counted_at
        FROM inventory_counts ic
        WHERE ic.counted_at <= p_counted_at
    ),
    status AS (
        -- For each part and round: where the system had it, and whether
        -- (and where) it was found.
        SELECT
            p.part_id,
            r.counted_at,
            sys.location_id                      AS system_location_id,
            sys.location_type                    AS system_location_type,
            found.location_id                    AS found_location_id
        FROM rounds r
        CROSS JOIN parts p
        -- Where the system had the part at that moment.
        JOIN LATERAL (
            SELECT l.location_id, l.location_type
            FROM locations l
            WHERE l.location_id = fn_location_at(p.part_id, r.counted_at)
        ) sys ON true
        -- Where the part was scanned in that round, if anywhere.
        LEFT JOIN LATERAL (
            SELECT ic.location_id
            FROM count_scans cs
            JOIN inventory_counts ic ON ic.count_id = cs.count_id
            WHERE cs.part_id = p.part_id
              AND ic.counted_at = r.counted_at
        ) found ON true
        WHERE sys.location_type <> 'SCRAP'
    ),
    relevant AS (
        -- Keep only the rounds that count for the part, and look back at
        -- the previous one.
        SELECT
            s.*,
            LAG(s.found_location_id IS NULL) OVER w AS missed_previous_round
        FROM status s
        WHERE s.found_location_id IS NOT NULL
           OR s.system_location_type = 'WAREHOUSE'
        WINDOW w AS (PARTITION BY s.part_id ORDER BY s.counted_at)
    ),
    decisions AS (
        SELECT
            r.part_id,
            r.system_location_id                 AS from_location_id,
            CASE WHEN r.found_location_id IS NOT NULL
                 THEN r.found_location_id
                 ELSE (SELECT location_id FROM locations WHERE location_type = 'SCRAP')
            END                                  AS to_location_id,
            CASE WHEN r.found_location_id IS NOT NULL
                 THEN 'Found during monthly count'
                 ELSE 'Not found in two consecutive counts - written off'
            END                                  AS reason
        FROM relevant r
        WHERE r.counted_at = p_counted_at
          AND (
                -- Found, but not where the system had it.
                (r.found_location_id IS NOT NULL
                 AND r.found_location_id <> r.system_location_id)
             OR -- Missing now and in the previous round that counted.
                (r.found_location_id IS NULL AND r.missed_previous_round)
          )
    )
    -- One minute apart, starting an hour after the count, in part order.
    SELECT
        d.part_id,
        d.from_location_id,
        d.to_location_id,
        date_trunc('day', p_counted_at) + interval '17 hours'
            + (ROW_NUMBER() OVER (ORDER BY d.part_id) - 1) * interval '1 minute',
        d.reason
    FROM decisions d
    ORDER BY d.part_id;
$$;

-- -----------------------------------------------------------------------------
-- Close a count round: post the corrections as ADJUSTMENT movements and
-- register the round as closed. Every adjustment still goes through the
-- validation trigger in 02_business_rules.sql.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_close_count_round(
    p_counted_at    timestamp,
    p_employee_code varchar
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_employee_id  smallint;
    v_shelves      integer;
    v_posted       integer;
BEGIN
    SELECT employee_id INTO v_employee_id
    FROM employees WHERE employee_code = p_employee_code;
    IF v_employee_id IS NULL THEN
        RAISE EXCEPTION 'Unknown employee %', p_employee_code;
    END IF;

    IF EXISTS (SELECT 1 FROM count_round_closures WHERE counted_at = p_counted_at) THEN
        RAISE EXCEPTION 'Count round % is already closed', p_counted_at
            USING HINT = 'Each round is closed once. Later fixes are new ADJUSTMENTs.';
    END IF;

    -- A round is closed only when every shelf has been counted.
    SELECT COUNT(*) INTO v_shelves
    FROM locations l
    WHERE l.location_type = 'WAREHOUSE'
      AND NOT EXISTS (SELECT 1 FROM inventory_counts ic
                      WHERE ic.location_id = l.location_id
                        AND ic.counted_at  = p_counted_at);
    IF v_shelves > 0 THEN
        RAISE EXCEPTION 'Count round % is incomplete: % shelves not counted',
            p_counted_at, v_shelves;
    END IF;

    INSERT INTO movements (part_id, movement_type, from_location_id, to_location_id,
                           moved_by, moved_at, notes)
    SELECT a.part_id, 'ADJUSTMENT', a.from_location_id, a.to_location_id,
           v_employee_id, a.adjusted_at, a.reason
    FROM fn_count_adjustments(p_counted_at) a;
    GET DIAGNOSTICS v_posted = ROW_COUNT;

    INSERT INTO count_round_closures (counted_at, closed_by, adjustments)
    VALUES (p_counted_at, v_employee_id, v_posted);

    RAISE NOTICE 'Count round % closed: % adjustments posted', p_counted_at, v_posted;
END;
$$;

-- -----------------------------------------------------------------------------
-- The rounds in the sample data were closed by the simulation. Register them,
-- with the adjustments that were actually posted for each one.
-- -----------------------------------------------------------------------------
INSERT INTO count_round_closures (counted_at, closed_by, closed_at, adjustments)
SELECT
    r.counted_at,
    MIN(ic.counted_by),
    r.counted_at + interval '1 hour',
    (SELECT COUNT(*) FROM movements m
     WHERE m.movement_type = 'ADJUSTMENT'
       AND m.moved_at::date = r.counted_at::date
       AND m.moved_at >= r.counted_at
       AND m.notes IN ('Found during monthly count',
                       'Not found in two consecutive counts - written off'))
FROM (SELECT DISTINCT counted_at FROM inventory_counts) r
JOIN inventory_counts ic ON ic.counted_at = r.counted_at
GROUP BY r.counted_at
ON CONFLICT (counted_at) DO NOTHING;
