-- Two tables: the parts and every movement recorded by the form.

DROP TABLE IF EXISTS movements;
DROP TABLE IF EXISTS parts;

CREATE TABLE parts (
    part_code  TEXT PRIMARY KEY,   -- the code printed in the QR label
    part_type  TEXT NOT NULL,
    customer   TEXT NOT NULL
);

CREATE TABLE movements (
    movement_id  INTEGER PRIMARY KEY,
    moved_at     TEXT NOT NULL,     -- date and time of the form answer
    moved_by     TEXT NOT NULL,
    part_code    TEXT NOT NULL REFERENCES parts (part_code),
    from_place   TEXT NOT NULL,
    to_place     TEXT NOT NULL,
    reason       TEXT NOT NULL
);
