-- Every runtime in runtimes.toml has at least one session, unless a session of
-- it was forgotten: forgetting its last session leaves it empty.
CREATE VIEW IF NOT EXISTS runtimes AS SELECT NULL::VARCHAR AS name WHERE false;
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS forgotten AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
SELECT 'runtime ' || r.name || ' has no sessions; run just sync and check its source, or remove it from runtimes.toml' AS action
FROM runtimes r
WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.runtime = r.name)
  AND NOT EXISTS (SELECT 1 FROM forgotten f WHERE f.runtime = r.name)
ORDER BY r.name;
