-- A session in the published lake must survive the build, unless forgotten.
CREATE VIEW IF NOT EXISTS published_sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id WHERE false;
CREATE VIEW IF NOT EXISTS forgotten AS SELECT NULL::VARCHAR AS session_id WHERE false;
SELECT 'session ' || p.session_id || ' (' || p.runtime || ') is in the published lake but not in this build; restore its mirror files, or run just forget ' || p.session_id || '. If the loss is right, move the lake aside and rebuild, and keep the moved lake' AS action
FROM published_sessions p
WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.session_id = p.session_id)
  AND NOT EXISTS (SELECT 1 FROM forgotten f WHERE f.session_id = p.session_id)
ORDER BY p.session_id;
