-- =============================================================================
-- 02_business_rules.sql
-- Rules enforced inside the database, so a bad form submission is rejected
-- instead of silently creating a divergence.
--
--   1. A part can only leave the place where the system says it is.
--   2. The movement type must match where the part is going.
--   3. Parts sent outside the site must have an expected return date.
--   4. Scrapped parts cannot move again.
--   5. Movements cannot be back-dated before the part's last movement.
--   6. The movement history is append-only (no UPDATE or DELETE).
--   7. A part's current location is always derived from its movements.
-- =============================================================================

SET search_path TO inventory;

-- -----------------------------------------------------------------------------
-- BEFORE INSERT on movements: validate the form submission, then move the
-- part in the system.
--
-- Both steps live in a BEFORE trigger on purpose. AFTER ROW triggers only
-- fire when the whole INSERT statement has finished, so in a multi-row insert
-- the second movement of a part would still see the part at its old location.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_process_movement()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_part      parts%ROWTYPE;
    v_from_code locations.location_code%TYPE;
    v_from_type locations.location_type%TYPE;
    v_from_ext  boolean;
    v_to_type   locations.location_type%TYPE;
    v_to_ext    boolean;
BEGIN
    -- Lock the part so two forms for the same part cannot race each other.
    SELECT * INTO v_part FROM parts WHERE part_id = NEW.part_id FOR UPDATE;

    SELECT location_type, is_external INTO v_to_type, v_to_ext
    FROM locations WHERE location_id = NEW.to_location_id;

    SELECT location_code, location_type, is_external INTO v_from_code, v_from_type, v_from_ext
    FROM locations WHERE location_id = NEW.from_location_id;

    IF NEW.movement_type = 'REGISTRATION' THEN
        -- First record of a new part, which always arrives at the warehouse.
        IF v_part.current_location_id IS NOT NULL THEN
            RAISE EXCEPTION 'Part % is already registered', v_part.qr_code;
        END IF;
        IF v_to_type <> 'WAREHOUSE' THEN
            RAISE EXCEPTION 'New parts must be registered into a warehouse location';
        END IF;

    ELSE
        IF v_part.current_location_id IS NULL THEN
            RAISE EXCEPTION 'Part % has not been registered yet', v_part.qr_code;
        END IF;

        -- Rule 1: the part must leave from where the system says it is.
        IF NEW.from_location_id <> v_part.current_location_id THEN
            RAISE EXCEPTION 'Part % is recorded at %, not at %',
                v_part.qr_code,
                (SELECT location_code FROM locations
                 WHERE location_id = v_part.current_location_id),
                v_from_code;
        END IF;

        -- Rule 4: scrapped parts are final.
        IF v_from_type = 'SCRAP' THEN
            RAISE EXCEPTION 'Part % has been scrapped and cannot be moved', v_part.qr_code;
        END IF;

        -- Rule 5: no back-dating.
        IF NEW.moved_at < v_part.last_movement_at THEN
            RAISE EXCEPTION 'Movement date % is before the last movement of part % (%)',
                NEW.moved_at, v_part.qr_code, v_part.last_movement_at;
        END IF;

        -- Rule 2: the movement type must match the route.
        IF NEW.movement_type = 'SHIPMENT' AND NOT v_to_ext THEN
            RAISE EXCEPTION 'A SHIPMENT must go to an external plant or supplier';
        ELSIF NEW.movement_type = 'RETURN'
              AND (NOT v_from_ext OR v_to_ext OR v_to_type = 'SCRAP') THEN
            RAISE EXCEPTION 'A RETURN must come from an external location back to the site';
        ELSIF NEW.movement_type = 'TRANSFER'
              AND (v_from_ext OR v_to_ext OR v_to_type = 'SCRAP') THEN
            RAISE EXCEPTION 'A TRANSFER must be between internal locations';
        ELSIF NEW.movement_type = 'SCRAP' AND v_to_type <> 'SCRAP' THEN
            RAISE EXCEPTION 'A SCRAP movement must go to the scrap area';
        END IF;

        -- Rule 3: anything sent outside needs a return date.
        IF NEW.movement_type = 'SHIPMENT' AND NEW.expected_return_date IS NULL THEN
            RAISE EXCEPTION 'Parts sent outside the site need an expected return date';
        END IF;
    END IF;

    -- Rule 7: the movement is valid, so the part moves in the system.
    UPDATE parts
    SET current_location_id = NEW.to_location_id,
        last_movement_at    = NEW.moved_at
    WHERE part_id = NEW.part_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_process_movement
BEFORE INSERT ON movements
FOR EACH ROW EXECUTE FUNCTION fn_process_movement();

-- -----------------------------------------------------------------------------
-- Rule 6: the history is the audit trail, so it cannot be rewritten.
-- Mistakes are corrected with a new ADJUSTMENT movement instead.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_block_history_changes()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'Movements are append-only (% blocked). Record an ADJUSTMENT instead.', TG_OP;
END;
$$;

CREATE TRIGGER trg_block_history_changes
BEFORE UPDATE OR DELETE ON movements
FOR EACH ROW EXECUTE FUNCTION fn_block_history_changes();

-- -----------------------------------------------------------------------------
-- Helper: where did the system think a part was at a given moment?
-- Used to compare a physical count with the records at that time.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_location_at(p_part_id integer, p_at timestamp)
RETURNS smallint
LANGUAGE sql
STABLE
AS $$
    SELECT m.to_location_id
    FROM movements m
    WHERE m.part_id = p_part_id
      AND m.moved_at <= p_at
    ORDER BY m.moved_at DESC, m.movement_id DESC
    LIMIT 1;
$$;
