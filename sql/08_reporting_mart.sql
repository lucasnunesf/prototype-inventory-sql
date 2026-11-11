-- =============================================================================
-- 08_reporting_mart.sql
-- A star schema for Power BI, in its own schema: `mart`.
--
-- The report reads only from here, never from the operational tables.
-- Dimensions and the movement fact are views, always current. The two
-- heavier tables (daily stock and monthly KPIs) are materialized views,
-- refreshed with CALL mart.sp_refresh().
--
--   dim_date  dim_part  dim_location  dim_employee
--        \       |          |            /
--         fact_movement      fact_daily_stock      kpi_monthly
--
-- Run after 07_count_closing.sql.
-- =============================================================================

DROP SCHEMA IF EXISTS mart CASCADE;
CREATE SCHEMA mart;
SET search_path TO mart, inventory;

-- -----------------------------------------------------------------------------
-- dim_date: one row per day, whole years around the data.
-- -----------------------------------------------------------------------------
CREATE TABLE mart.dim_date AS
WITH days AS (
    SELECT d::date AS full_date
    FROM generate_series(
        (SELECT date_trunc('year', MIN(moved_at)) FROM inventory.movements),
        (SELECT date_trunc('year', MAX(moved_at)) + interval '1 year - 1 day'
         FROM inventory.movements),
        interval '1 day') AS d
)
SELECT
    to_char(full_date, 'YYYYMMDD')::integer           AS date_key,
    full_date,
    EXTRACT(year    FROM full_date)::smallint          AS year,
    EXTRACT(quarter FROM full_date)::smallint          AS quarter,
    EXTRACT(month   FROM full_date)::smallint          AS month,
    to_char(full_date, 'Mon YYYY')                     AS month_label,
    date_trunc('month', full_date)::date               AS month_start,
    EXTRACT(week    FROM full_date)::smallint          AS iso_week,
    to_char(full_date, 'Dy')                           AS weekday,
    EXTRACT(isodow  FROM full_date) < 6                AS is_business_day,
    -- The monthly count is done on the last business day of the month.
    full_date = MAX(full_date) FILTER (WHERE EXTRACT(isodow FROM full_date) < 6)
                OVER (PARTITION BY date_trunc('month', full_date))
                                                       AS is_count_day
FROM days;

ALTER TABLE mart.dim_date ADD PRIMARY KEY (date_key);
CREATE UNIQUE INDEX ux_dim_date_full_date ON mart.dim_date (full_date);

-- -----------------------------------------------------------------------------
-- Dimensions
-- -----------------------------------------------------------------------------
CREATE VIEW mart.dim_location AS
SELECT
    l.location_id                                  AS location_key,
    l.location_code,
    l.location_type,
    l.description,
    l.is_external,
    -- Shelf positions are WH-<aisle>-<level>.
    CASE WHEN l.location_type = 'WAREHOUSE'
         THEN split_part(l.location_code, '-', 2) END AS aisle,
    CASE l.location_type
        WHEN 'WAREHOUSE'      THEN 'On a shelf'
        WHEN 'WORKSHOP'       THEN 'In use on site'
        WHEN 'TEST_LAB'       THEN 'In use on site'
        WHEN 'EXTERNAL_PLANT' THEN 'Outside the site'
        WHEN 'SUPPLIER'       THEN 'Outside the site'
        ELSE                       'Scrapped'
    END                                            AS location_group
FROM inventory.locations l;

CREATE VIEW mart.dim_part AS
SELECT
    p.part_id                                      AS part_key,
    p.qr_code,
    pt.part_type_code,
    pt.description                                 AS part_description,
    c.customer_code,
    c.customer_name,
    pr.project_code,
    pr.project_name,
    first_mv.moved_at::date                        AS registered_on,
    l.location_code                                AS current_location,
    l.location_type = 'SCRAP'                      AS is_scrapped
FROM inventory.parts p
JOIN inventory.part_types pt ON pt.part_type_id = p.part_type_id
JOIN inventory.projects   pr ON pr.project_id   = p.project_id
JOIN inventory.customers  c  ON c.customer_id   = pr.customer_id
LEFT JOIN inventory.locations l ON l.location_id = p.current_location_id
LEFT JOIN LATERAL (
    SELECT m.moved_at FROM inventory.movements m
    WHERE m.part_id = p.part_id AND m.movement_type = 'REGISTRATION'
) first_mv ON true;

CREATE VIEW mart.dim_employee AS
SELECT employee_id AS employee_key, employee_code, team
FROM inventory.employees;

-- -----------------------------------------------------------------------------
-- fact_movement: one row per form, with how long the part stayed where it
-- went, and for shipments, when it came back and how late.
-- -----------------------------------------------------------------------------
CREATE VIEW mart.fact_movement AS
WITH ordered AS (
    SELECT
        m.*,
        LEAD(m.moved_at)      OVER w AS next_moved_at,
        LEAD(m.movement_type) OVER w AS next_movement_type
    FROM inventory.movements m
    WINDOW w AS (PARTITION BY m.part_id ORDER BY m.moved_at, m.movement_id)
)
SELECT
    o.movement_id,
    to_char(o.moved_at, 'YYYYMMDD')::integer       AS date_key,
    o.part_id                                      AS part_key,
    o.from_location_id                             AS from_location_key,
    o.to_location_id                               AS to_location_key,
    o.moved_by                                     AS employee_key,
    o.movement_type,
    o.moved_at,
    -- Hours at the destination; NULL while the part is still there.
    ROUND(EXTRACT(epoch FROM o.next_moved_at - o.moved_at) / 3600, 1)
                                                   AS hours_at_destination,
    o.notes LIKE 'Form rejected%'                  AS fixes_rejected_form,
    o.movement_type = 'ADJUSTMENT'                 AS is_correction,
    o.expected_return_date,
    CASE WHEN o.movement_type = 'SHIPMENT' AND o.next_movement_type = 'RETURN'
         THEN o.next_moved_at::date END            AS returned_on,
    CASE WHEN o.movement_type = 'SHIPMENT' AND o.next_movement_type = 'RETURN'
         THEN GREATEST(o.next_moved_at::date - o.expected_return_date, 0) END
                                                   AS days_late
FROM ordered o;

-- -----------------------------------------------------------------------------
-- fact_daily_stock: how many parts were at each location at the end of
-- each day. Each movement opens a stay [moved_at, next moved_at); a day is
-- counted where the stay covers its last moment.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.fact_daily_stock AS
WITH stays AS (
    SELECT
        m.part_id,
        m.to_location_id,
        m.moved_at                                          AS stay_from,
        COALESCE(LEAD(m.moved_at) OVER (PARTITION BY m.part_id
                                        ORDER BY m.moved_at, m.movement_id),
                 'infinity'::timestamp)                     AS stay_to
    FROM inventory.movements m
),
data_range AS (
    SELECT MIN(moved_at)::date AS first_day, MAX(moved_at)::date AS last_day
    FROM inventory.movements
)
SELECT
    d.date_key,
    s.to_location_id                                AS location_key,
    COUNT(*)::integer                               AS parts_on_hand
FROM mart.dim_date d
CROSS JOIN data_range r
JOIN stays s
  ON (d.full_date + 1)::timestamp >  s.stay_from
 AND (d.full_date + 1)::timestamp <= s.stay_to
WHERE d.full_date BETWEEN r.first_day AND r.last_day
GROUP BY d.date_key, s.to_location_id;

-- A unique index lets the view be refreshed without locking the report.
CREATE UNIQUE INDEX ux_fact_daily_stock ON mart.fact_daily_stock (date_key, location_key);

-- -----------------------------------------------------------------------------
-- kpi_monthly: the numbers on the first page of the report.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mart.kpi_monthly AS
WITH months AS (
    SELECT DISTINCT d.month_start,
           (d.month_start + interval '1 month - 1 day')::date AS month_end
    FROM mart.dim_date d
    WHERE d.month_start BETWEEN (SELECT date_trunc('month', MIN(moved_at)) FROM inventory.movements)
                            AND (SELECT date_trunc('month', MAX(moved_at)) FROM inventory.movements)
),
flows AS (
    SELECT
        date_trunc('month', f.moved_at)::date                       AS month_start,
        COUNT(*)                                                    AS movements,
        COUNT(*) FILTER (WHERE f.movement_type = 'REGISTRATION')    AS parts_registered,
        COUNT(*) FILTER (WHERE f.movement_type = 'SHIPMENT')        AS shipments,
        COUNT(*) FILTER (WHERE f.movement_type = 'RETURN')          AS returns,
        COUNT(*) FILTER (WHERE f.fixes_rejected_form)               AS rejected_forms_fixed,
        COUNT(*) FILTER (WHERE f.is_correction
                           AND NOT f.fixes_rejected_form)           AS count_corrections
    FROM mart.fact_movement f
    GROUP BY 1
),
returns AS (
    -- Shipments by the month they came back.
    SELECT
        date_trunc('month', f.returned_on)::date                    AS month_start,
        ROUND(100.0 * COUNT(*) FILTER (WHERE f.days_late = 0) / COUNT(*), 1)
                                                                    AS returned_on_time_pct
    FROM mart.fact_movement f
    WHERE f.returned_on IS NOT NULL
    GROUP BY 1
)
SELECT
    m.month_start,
    to_char(m.month_start, 'Mon YYYY')                              AS month_label,
    COALESCE(fl.movements, 0)                                       AS movements,
    COALESCE(fl.parts_registered, 0)                                AS parts_registered,
    COALESCE(fl.shipments, 0)                                       AS shipments,
    COALESCE(fl.returns, 0)                                         AS returns,
    rt.returned_on_time_pct,
    COALESCE(fl.rejected_forms_fixed, 0)                            AS rejected_forms_fixed,
    COALESCE(fl.count_corrections, 0)                               AS count_corrections,
    acc.accuracy_pct                                                AS count_accuracy_pct,
    -- Snapshot at the end of the month.
    (SELECT SUM(s.parts_on_hand) FROM mart.fact_daily_stock s
     JOIN mart.dim_location l ON l.location_key = s.location_key
     WHERE s.date_key = to_char(m.month_end, 'YYYYMMDD')::integer
       AND l.location_type <> 'SCRAP')                              AS active_parts_month_end,
    -- Parts outside and past their return date, as they were that day
    -- (not as they are now).
    (SELECT COUNT(*) FROM inventory.parts p
     CROSS JOIN LATERAL (
         SELECT mv.to_location_id, mv.expected_return_date
         FROM inventory.movements mv
         WHERE mv.part_id = p.part_id
           AND mv.moved_at < m.month_end + 1
         ORDER BY mv.moved_at DESC, mv.movement_id DESC
         LIMIT 1) last_mv
     JOIN inventory.locations l ON l.location_id = last_mv.to_location_id
     WHERE l.is_external
       AND last_mv.expected_return_date < m.month_end)              AS overdue_outside_month_end
FROM months m
LEFT JOIN flows   fl  ON fl.month_start = m.month_start
LEFT JOIN returns rt  ON rt.month_start = m.month_start
LEFT JOIN inventory.v_count_accuracy acc
       ON date_trunc('month', acc.count_date) = m.month_start
ORDER BY m.month_start;

CREATE UNIQUE INDEX ux_kpi_monthly ON mart.kpi_monthly (month_start);

-- -----------------------------------------------------------------------------
-- Refresh after new movements or a closed count. CONCURRENTLY keeps the
-- old numbers readable while the new ones are computed.
-- -----------------------------------------------------------------------------
CREATE PROCEDURE mart.sp_refresh()
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.fact_daily_stock;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mart.kpi_monthly;
END;
$$;
