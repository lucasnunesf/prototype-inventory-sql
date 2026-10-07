-- =============================================================================
-- 03_views.sql
-- The questions the old spreadsheet answered with filters and lookups,
-- now answered by the database itself.
-- =============================================================================

SET search_path TO inventory;

-- -----------------------------------------------------------------------------
-- Where is every active part right now?
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_current_stock AS
SELECT
    p.qr_code,
    pt.part_type_code,
    pt.description          AS part_description,
    c.customer_code,
    pr.project_code,
    l.location_code,
    l.location_type,
    p.last_movement_at
FROM parts p
JOIN part_types pt ON pt.part_type_id = p.part_type_id
JOIN projects   pr ON pr.project_id   = p.project_id
JOIN customers  c  ON c.customer_id   = pr.customer_id
JOIN locations  l  ON l.location_id   = p.current_location_id
WHERE l.location_type <> 'SCRAP';

-- -----------------------------------------------------------------------------
-- Full, readable history of every part (the audit trail).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_movement_history AS
SELECT
    m.movement_id,
    p.qr_code,
    m.movement_type,
    lf.location_code        AS from_location,
    lt.location_code        AS to_location,
    e.employee_code         AS moved_by,
    m.moved_at,
    m.expected_return_date,
    m.notes
FROM movements m
JOIN parts          p  ON p.part_id      = m.part_id
LEFT JOIN locations lf ON lf.location_id = m.from_location_id
JOIN locations      lt ON lt.location_id = m.to_location_id
JOIN employees      e  ON e.employee_id  = m.moved_by;

-- -----------------------------------------------------------------------------
-- Parts currently outside the site, and whether they are late.
-- A function instead of a view so the reference date can be chosen
-- (the sample data ends on 2026-09-30).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_parts_outside(p_ref_date date DEFAULT current_date)
RETURNS TABLE (
    qr_code              varchar,
    customer_code        varchar,
    project_code         varchar,
    location_code        varchar,
    location_type        varchar,
    sent_by              varchar,
    sent_at              timestamp,
    expected_return_date date,
    days_overdue         integer,
    status               text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        p.qr_code,
        c.customer_code,
        pr.project_code,
        l.location_code,
        l.location_type,
        e.employee_code,
        last_mv.moved_at,
        last_mv.expected_return_date,
        GREATEST(p_ref_date - last_mv.expected_return_date, 0),
        CASE
            WHEN last_mv.expected_return_date IS NULL      THEN 'NO RETURN DATE'
            WHEN last_mv.expected_return_date < p_ref_date THEN 'OVERDUE'
            ELSE 'ON TIME'
        END
    FROM parts p
    JOIN locations l  ON l.location_id  = p.current_location_id
    JOIN projects  pr ON pr.project_id  = p.project_id
    JOIN customers c  ON c.customer_id  = pr.customer_id
    -- The movement that took the part to where it is now.
    CROSS JOIN LATERAL (
        SELECT m.moved_at, m.moved_by, m.expected_return_date
        FROM movements m
        WHERE m.part_id = p.part_id
        ORDER BY m.moved_at DESC, m.movement_id DESC
        LIMIT 1
    ) last_mv
    JOIN employees e ON e.employee_id = last_mv.moved_by
    WHERE l.is_external;
$$;

-- -----------------------------------------------------------------------------
-- Count reconciliation: physical count vs. what the system said at that moment.
--
--   MATCH       the system said it was here, and it was found here
--   MISSING     the system said it was here, but it was not found
--   UNRECORDED  it was found here, but the system had it somewhere else
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_count_reconciliation AS
WITH expected AS (
    -- Parts the system placed at the counted location at the time of the count.
    SELECT ic.count_id, p.part_id
    FROM inventory_counts ic
    CROSS JOIN parts p
    WHERE fn_location_at(p.part_id, ic.counted_at) = ic.location_id
),
compared AS (
    SELECT
        COALESCE(e.count_id, cs.count_id) AS count_id,
        COALESCE(e.part_id,  cs.part_id)  AS part_id,
        CASE
            WHEN e.part_id IS NOT NULL AND cs.part_id IS NOT NULL THEN 'MATCH'
            WHEN e.part_id IS NOT NULL                            THEN 'MISSING'
            ELSE                                                       'UNRECORDED'
        END AS result
    FROM expected e
    FULL JOIN count_scans cs
           ON cs.count_id = e.count_id
          AND cs.part_id  = e.part_id
)
SELECT
    ic.count_id,
    ic.counted_at,
    l.location_code                        AS counted_location,
    p.qr_code,
    cmp.result,
    sl.location_code                       AS system_location_at_count
FROM compared cmp
JOIN inventory_counts ic ON ic.count_id  = cmp.count_id
JOIN locations        l  ON l.location_id = ic.location_id
JOIN parts            p  ON p.part_id     = cmp.part_id
LEFT JOIN locations   sl ON sl.location_id = fn_location_at(p.part_id, ic.counted_at);

-- -----------------------------------------------------------------------------
-- Inventory accuracy per count round (all shelves counted on the same day).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_count_accuracy AS
SELECT
    counted_at::date                                         AS count_date,
    COUNT(*) FILTER (WHERE result = 'MATCH')                 AS matched,
    COUNT(*) FILTER (WHERE result = 'MISSING')               AS missing,
    COUNT(*) FILTER (WHERE result = 'UNRECORDED')            AS unrecorded,
    ROUND(100.0 * COUNT(*) FILTER (WHERE result = 'MATCH') / COUNT(*), 1)
                                                             AS accuracy_pct
FROM v_count_reconciliation
GROUP BY counted_at::date;
