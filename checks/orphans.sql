-- A message, api call or tool call belongs to a session the lake holds.
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
WITH child AS (
  SELECT 'messages' AS tbl, runtime, session_id FROM messages
  UNION ALL SELECT 'api_calls', runtime, session_id FROM api_calls
  UNION ALL SELECT 'tool_calls', runtime, session_id FROM tool_calls
)
SELECT c.tbl || ' has ' || count(*) || ' row(s) for ' || c.runtime || ' with no session; the adapter wrote a child without its session, or the session was dropped' AS action
FROM child c
WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.runtime = c.runtime AND s.session_id = c.session_id)
GROUP BY c.tbl, c.runtime
ORDER BY c.tbl, c.runtime;
