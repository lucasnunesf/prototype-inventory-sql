-- Three views. Each one becomes a CSV file that Power BI reads.

-- 1. Where every part is now: its most recent movement.
DROP VIEW IF EXISTS v_current_location;
CREATE VIEW v_current_location AS
WITH ranked AS (
    SELECT
        m.part_code,
        m.to_place  AS current_place,
        m.moved_at  AS last_moved_at,
        ROW_NUMBER() OVER (PARTITION BY m.part_code ORDER BY m.moved_at DESC) AS rn
    FROM movements m
)
SELECT
    p.part_code,
    p.part_type,
    p.customer,
    r.current_place,
    r.last_moved_at
FROM parts p
JOIN ranked r ON r.part_code = p.part_code AND r.rn = 1;


-- 2. How many movements happened each month, by reason.
DROP VIEW IF EXISTS v_movements_by_month;
CREATE VIEW v_movements_by_month AS
SELECT
    substr(moved_at, 1, 7) AS month,
    reason,
    COUNT(*) AS movements
FROM movements
GROUP BY month, reason;


-- 3. Parts that are outside the site and for how many days.
--    The reference date is the last form answer in the data.
DROP VIEW IF EXISTS v_parts_outside;
CREATE VIEW v_parts_outside AS
SELECT
    c.part_code,
    c.part_type,
    c.customer,
    c.current_place,
    c.last_moved_at AS sent_at,
    CAST(julianday((SELECT MAX(moved_at) FROM movements)) - julianday(c.last_moved_at) AS INTEGER) AS days_outside
FROM v_current_location c
WHERE c.current_place IN ('Supplier', 'Other plant');
