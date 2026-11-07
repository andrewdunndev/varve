-- A forgotten session must be gone from the lake.
CREATE VIEW IF NOT EXISTS forgotten AS SELECT NULL::VARCHAR AS session_id WHERE false;
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id WHERE false;
SELECT 'session ' || f.session_id || ' is forgotten but still in the lake; run just build' AS action
FROM forgotten f
WHERE EXISTS (SELECT 1 FROM sessions s WHERE s.session_id = f.session_id)
ORDER BY f.session_id;
