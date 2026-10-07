-- =============================================================================
-- 05_analysis_queries.sql
-- Questions the team asks about the prototype parts, answered in SQL.
-- The sample data ends on 2026-09-30, so that date is used as "today".
-- =============================================================================

SET search_path TO inventory;

-- -----------------------------------------------------------------------------
-- Q1. How many active parts does each customer have, and where are they?
-- -----------------------------------------------------------------------------
SELECT
    customer_code,
    COUNT(*) FILTER (WHERE location_type = 'WAREHOUSE')                       AS warehouse,
    COUNT(*) FILTER (WHERE location_type IN ('WORKSHOP', 'TEST_LAB'))         AS in_work,
    COUNT(*) FILTER (WHERE location_type IN ('EXTERNAL_PLANT', 'SUPPLIER'))   AS outside,
    COUNT(*)                                                                  AS total
FROM v_current_stock
GROUP BY customer_code
ORDER BY total DESC;

-- -----------------------------------------------------------------------------
-- Q2. Which parts are outside the site and late? Who sent them?
-- -----------------------------------------------------------------------------
SELECT qr_code, customer_code, location_code, sent_by, sent_at::date,
       expected_return_date, days_overdue
FROM fn_parts_outside('2026-09-30')
WHERE status = 'OVERDUE'
ORDER BY days_overdue DESC;

-- -----------------------------------------------------------------------------
-- Q3. Complete history of one part: every place it has been, and who moved it.
--     After 2026-07-15 this part was taken back to the lab without a form.
--     On 2026-07-21 the next form was rejected, an ADJUSTMENT fixed the
--     record, and the movement went through five minutes later.
-- -----------------------------------------------------------------------------
SELECT moved_at, movement_type, from_location, to_location, moved_by, notes
FROM v_movement_history
WHERE qr_code = 'QR-00303'
ORDER BY moved_at, movement_id;

-- -----------------------------------------------------------------------------
-- Q4. Inventory accuracy per monthly count.
-- -----------------------------------------------------------------------------
SELECT * FROM v_count_accuracy ORDER BY count_date;

-- -----------------------------------------------------------------------------
-- Q5. Divergences found in the last count, and where the system had the part.
-- -----------------------------------------------------------------------------
SELECT counted_location, qr_code, result, system_location_at_count
FROM v_count_reconciliation
WHERE counted_at = (SELECT MAX(counted_at) FROM inventory_counts)
  AND result <> 'MATCH'
ORDER BY result, counted_location;

-- -----------------------------------------------------------------------------
-- Q6. Shipments and returns: how long do parts stay outside, per destination,
--     and how many come back on time?
--     Each SHIPMENT is paired with the part's next movement using LEAD().
-- -----------------------------------------------------------------------------
WITH part_moves AS (
    SELECT
        m.part_id,
        m.movement_type,
        m.to_location_id,
        m.moved_at,
        m.expected_return_date,
        LEAD(m.movement_type) OVER w AS next_type,
        LEAD(m.moved_at)      OVER w AS next_moved_at
    FROM movements m
    WINDOW w AS (PARTITION BY m.part_id ORDER BY m.moved_at, m.movement_id)
)
SELECT
    l.location_code                                                    AS destination,
    COUNT(*)                                                           AS shipments,
    COUNT(*) FILTER (WHERE pm.next_type = 'RETURN')                    AS returned,
    ROUND(AVG(pm.next_moved_at::date - pm.moved_at::date)
          FILTER (WHERE pm.next_type = 'RETURN'), 1)                   AS avg_days_outside,
    ROUND(100.0 * COUNT(*) FILTER (WHERE pm.next_type = 'RETURN'
                                     AND pm.next_moved_at::date <= pm.expected_return_date)
          / NULLIF(COUNT(*) FILTER (WHERE pm.next_type = 'RETURN'), 0), 1)
                                                                       AS on_time_pct
FROM part_moves pm
JOIN locations l ON l.location_id = pm.to_location_id
WHERE pm.movement_type = 'SHIPMENT'
GROUP BY l.location_code
ORDER BY shipments DESC;

-- -----------------------------------------------------------------------------
-- Q7. How often did the records have to be corrected, and why? (per month)
-- -----------------------------------------------------------------------------
SELECT
    date_trunc('month', moved_at)::date      AS month,
    notes                                    AS reason,
    COUNT(*)                                 AS adjustments
FROM movements
WHERE movement_type = 'ADJUSTMENT'
GROUP BY 1, 2
ORDER BY 1, 2;

-- -----------------------------------------------------------------------------
-- Q8. Parts sitting untouched on a shelf for more than 60 days
--     (candidates to return to the customer or free up space).
-- -----------------------------------------------------------------------------
SELECT qr_code, customer_code, project_code, location_code,
       last_movement_at::date,
       DATE '2026-09-30' - last_movement_at::date AS days_idle
FROM v_current_stock
WHERE location_type = 'WAREHOUSE'
  AND last_movement_at < DATE '2026-09-30' - 60
ORDER BY days_idle DESC;

-- -----------------------------------------------------------------------------
-- Q9. Shelf occupancy: busiest positions and their share of the warehouse.
-- -----------------------------------------------------------------------------
SELECT
    location_code,
    COUNT(*)                                                  AS parts,
    RANK() OVER (ORDER BY COUNT(*) DESC)                      AS rank,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)        AS share_pct
FROM v_current_stock
WHERE location_type = 'WAREHOUSE'
GROUP BY location_code
ORDER BY parts DESC
LIMIT 10;
