CREATE TABLE IF NOT EXISTS healthcheck (
    id integer PRIMARY KEY,
    message text NOT NULL
);

INSERT INTO healthcheck (id, message)
VALUES (1, 'postgres-ok')
ON CONFLICT (id)
DO UPDATE SET message = EXCLUDED.message;