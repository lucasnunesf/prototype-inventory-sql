-- Five questions the prototype area asked every week.

-- 1. How many parts are in each place right now?
SELECT current_place, COUNT(*) AS parts
FROM v_current_location
GROUP BY current_place
ORDER BY parts DESC;

-- 2. Which parts have been outside for more than 30 days? (chase these first)
SELECT part_code, part_type, customer, current_place, days_outside
FROM v_parts_outside
WHERE days_outside > 30
ORDER BY days_outside DESC;

-- 3. Which customers have the most parts in the area?
SELECT customer, COUNT(*) AS parts
FROM parts
GROUP BY customer
ORDER BY parts DESC;

-- 4. Who recorded the most movements?
SELECT moved_by, COUNT(*) AS movements
FROM movements
GROUP BY moved_by
ORDER BY movements DESC;

-- 5. Full history of one part, oldest first.
SELECT moved_at, from_place, to_place, reason, moved_by
FROM movements
WHERE part_code = 'QR-0001'
ORDER BY moved_at;
