-- =============================================================================
-- 01_schema.sql
-- Prototype parts inventory: tables, keys and constraints.
--
-- Every physical prototype part has its own QR code. Scanning it opens a form
-- that records where the part came from and where it is going. Each form
-- submission becomes one row in `movements`, and the part's current location
-- is derived from that history (see 02_business_rules.sql).
-- =============================================================================

DROP SCHEMA IF EXISTS inventory CASCADE;
CREATE SCHEMA inventory;
SET search_path TO inventory;

-- -----------------------------------------------------------------------------
-- Reference data
-- -----------------------------------------------------------------------------

CREATE TABLE customers (
    customer_id     smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_code   varchar(10) NOT NULL UNIQUE,
    customer_name   varchar(80) NOT NULL
);

CREATE TABLE projects (
    project_id      smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     smallint    NOT NULL REFERENCES customers (customer_id),
    project_code    varchar(20) NOT NULL UNIQUE,
    project_name    varchar(80) NOT NULL
);

CREATE TABLE part_types (
    part_type_id    smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    part_type_code  varchar(10) NOT NULL UNIQUE,
    description     varchar(80) NOT NULL
);

-- Every place a part can be: a shelf position, a workshop, the test lab,
-- another plant, a supplier, or the scrap area.
CREATE TABLE locations (
    location_id     smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_code   varchar(20) NOT NULL UNIQUE,
    location_type   varchar(20) NOT NULL
        CHECK (location_type IN ('WAREHOUSE', 'WORKSHOP', 'TEST_LAB',
                                 'EXTERNAL_PLANT', 'SUPPLIER', 'SCRAP')),
    description     varchar(80) NOT NULL,
    -- Parts sent outside the site are expected to come back by a given date.
    is_external     boolean     GENERATED ALWAYS AS
                        (location_type IN ('EXTERNAL_PLANT', 'SUPPLIER')) STORED
);

CREATE TABLE employees (
    employee_id     smallint    GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_code   varchar(10) NOT NULL UNIQUE,
    team            varchar(40) NOT NULL
);

-- -----------------------------------------------------------------------------
-- Parts: one row per physical part (one QR code each)
-- -----------------------------------------------------------------------------

CREATE TABLE parts (
    part_id             integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    qr_code             varchar(20) NOT NULL UNIQUE,
    part_type_id        smallint    NOT NULL REFERENCES part_types (part_type_id),
    project_id          smallint    NOT NULL REFERENCES projects (project_id),
    -- Maintained by trigger from `movements`. Never written directly.
    current_location_id smallint    REFERENCES locations (location_id),
    last_movement_at    timestamp
);

CREATE INDEX ix_parts_current_location ON parts (current_location_id);
CREATE INDEX ix_parts_project          ON parts (project_id);

-- -----------------------------------------------------------------------------
-- Movements: the form submissions. Append-only history of every part.
-- -----------------------------------------------------------------------------

CREATE TABLE movements (
    movement_id          bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    part_id              integer     NOT NULL REFERENCES parts (part_id),
    movement_type        varchar(20) NOT NULL
        CHECK (movement_type IN ('REGISTRATION', 'TRANSFER', 'SHIPMENT',
                                 'RETURN', 'SCRAP', 'ADJUSTMENT')),
    from_location_id     smallint    REFERENCES locations (location_id),
    to_location_id       smallint    NOT NULL REFERENCES locations (location_id),
    moved_by             smallint    NOT NULL REFERENCES employees (employee_id),
    moved_at             timestamp   NOT NULL,
    expected_return_date date,
    notes                varchar(200),

    -- A movement must actually go somewhere.
    CONSTRAINT chk_movement_changes_location
        CHECK (from_location_id IS DISTINCT FROM to_location_id),
    -- Only the first record of a part (its registration) has no origin.
    CONSTRAINT chk_only_registration_has_no_origin
        CHECK ((movement_type = 'REGISTRATION') = (from_location_id IS NULL)),
    -- A return date cannot be before the shipment itself.
    CONSTRAINT chk_return_date_after_movement
        CHECK (expected_return_date IS NULL OR expected_return_date >= moved_at::date)
);

CREATE INDEX ix_movements_part_time ON movements (part_id, moved_at);
CREATE INDEX ix_movements_to_loc    ON movements (to_location_id);

-- -----------------------------------------------------------------------------
-- Physical counts: what was actually found on the shelves
-- -----------------------------------------------------------------------------

-- One count = one location checked at one moment.
CREATE TABLE inventory_counts (
    count_id        integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    location_id     smallint    NOT NULL REFERENCES locations (location_id),
    counted_at      timestamp   NOT NULL,
    counted_by      smallint    NOT NULL REFERENCES employees (employee_id),
    UNIQUE (location_id, counted_at)
);

-- Every QR code scanned during that count.
CREATE TABLE count_scans (
    count_id        integer     NOT NULL REFERENCES inventory_counts (count_id),
    part_id         integer     NOT NULL REFERENCES parts (part_id),
    PRIMARY KEY (count_id, part_id)
);
