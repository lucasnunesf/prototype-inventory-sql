-- =============================================================================
-- 09_access_roles.sql
-- Who can do what. Three roles, one per way the database is used:
--
--   inv_form_app    the QR code form. Reads codes, inserts movements.
--                   Cannot post an ADJUSTMENT (row-level security).
--   inv_logistics   the logistics team. Everything the form can do, plus
--                   ADJUSTMENTs and closing a count round.
--   inv_bi_reader   Power BI. Reads the `mart` schema only.
--
-- Nobody can UPDATE or DELETE a movement (02_business_rules.sql), and
-- nobody writes parts.current_location_id directly: only the trigger does.
--
-- Roles belong to the whole server, so they are created only if missing.
-- Run after 08_reporting_mart.sql.
-- =============================================================================

SET search_path TO inventory;

DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['inv_form_app', 'inv_logistics', 'inv_bi_reader'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END;
$$;

-- Logistics can do everything the form can.
GRANT inv_form_app TO inv_logistics;

-- -----------------------------------------------------------------------------
-- The form: look up codes, insert movements, nothing else.
-- -----------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA inventory FROM PUBLIC;
GRANT USAGE ON SCHEMA inventory TO inv_form_app;
GRANT SELECT ON parts, locations, employees, part_types, projects, customers
    TO inv_form_app;
GRANT SELECT, INSERT ON movements TO inv_form_app;
GRANT SELECT ON v_current_stock, v_movement_history TO inv_form_app;

-- The trigger moves the part in `parts`, which the form cannot write.
-- It runs with the rights of its owner, with a fixed search_path so it
-- cannot be tricked into using someone else's tables.
ALTER FUNCTION fn_process_movement() SECURITY DEFINER SET search_path = inventory, pg_temp;

-- -----------------------------------------------------------------------------
-- Logistics: counts, closing a round and reading every view.
-- -----------------------------------------------------------------------------
GRANT SELECT, INSERT ON inventory_counts, count_scans TO inv_logistics;
GRANT SELECT ON count_round_closures TO inv_logistics;
GRANT SELECT ON v_count_reconciliation, v_count_accuracy TO inv_logistics;
GRANT EXECUTE ON FUNCTION fn_parts_outside(date) TO inv_logistics;

-- Closing a round writes the closure table, so it runs as its owner too.
ALTER PROCEDURE sp_close_count_round(timestamp, varchar)
    SECURITY DEFINER SET search_path = inventory, pg_temp;
REVOKE EXECUTE ON PROCEDURE sp_close_count_round(timestamp, varchar) FROM PUBLIC;
GRANT EXECUTE ON PROCEDURE sp_close_count_round(timestamp, varchar) TO inv_logistics;

-- -----------------------------------------------------------------------------
-- Row-level security: only logistics can post an ADJUSTMENT.
-- A form that tries to "fix" a location itself is refused.
-- The table owner (who loads the sample data) is not affected.
-- -----------------------------------------------------------------------------
ALTER TABLE movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_read_all            ON movements;
DROP POLICY IF EXISTS p_form_no_adjustments ON movements;
DROP POLICY IF EXISTS p_logistics_insert    ON movements;

CREATE POLICY p_read_all ON movements
    FOR SELECT TO inv_form_app
    USING (true);

CREATE POLICY p_form_no_adjustments ON movements
    FOR INSERT TO inv_form_app
    WITH CHECK (movement_type <> 'ADJUSTMENT');

CREATE POLICY p_logistics_insert ON movements
    FOR INSERT TO inv_logistics
    WITH CHECK (true);

-- -----------------------------------------------------------------------------
-- Power BI: the mart and nothing else. The mart views read the operational
-- tables with their owner's rights, so the report needs no access to them.
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA mart TO inv_bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO inv_bi_reader;
REVOKE ALL ON SCHEMA inventory FROM inv_bi_reader;

-- -----------------------------------------------------------------------------
-- What each role can actually do, straight from the catalog. Inherited
-- rights count (logistics gets the form's), and materialized views are
-- included, which information_schema leaves out.
-- -----------------------------------------------------------------------------
WITH rights AS (
    SELECT
        r.rolname,
        n.nspname,
        c.relname,
        string_agg(p.priv, '+' ORDER BY p.ord)     AS privileges
    FROM pg_roles r
    CROSS JOIN pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN (VALUES (1, 'SELECT'), (2, 'INSERT'), (3, 'UPDATE'), (4, 'DELETE')) AS p (ord, priv)
    WHERE r.rolname LIKE 'inv\_%'
      AND n.nspname IN ('inventory', 'mart')
      AND c.relkind IN ('r', 'v', 'm')             -- tables, views, materialized views
      AND has_schema_privilege(r.rolname, n.oid, 'USAGE')
      AND has_table_privilege(r.rolname, c.oid, p.priv)
    GROUP BY r.rolname, n.nspname, c.relname
)
SELECT
    rolname                                        AS role,
    privileges,
    COUNT(*)                                       AS objects,
    string_agg(nspname || '.' || relname, ', ' ORDER BY nspname, relname) AS on_objects
FROM rights
GROUP BY rolname, privileges
ORDER BY rolname, privileges DESC;
