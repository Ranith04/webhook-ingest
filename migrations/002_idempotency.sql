-- First, clean up any existing duplicates by keeping the one with the highest id
DELETE FROM events
WHERE id NOT IN (
    SELECT max(id)
    FROM events
    GROUP BY event_id
);

-- Now add the unique constraint
ALTER TABLE events ADD CONSTRAINT events_event_id_key UNIQUE (event_id);
