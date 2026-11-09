-- Each core table holds one row per key: a session per (runtime, session_id), a
-- message per (runtime, session_id, message_id), an api call per (runtime,
-- session_id, message_id), a tool call per (runtime, session_id, tool_use_id).
-- A repeated key double-counts in every sum, so the adapter must collapse it.
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::VARCHAR AS message_id WHERE false;
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::VARCHAR AS message_id WHERE false;
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::VARCHAR AS tool_use_id WHERE false;
WITH dup AS (
  SELECT 'sessions' AS tbl, runtime, count(*) - count(DISTINCT session_id) AS n
  FROM sessions GROUP BY runtime
  UNION ALL
  SELECT 'messages', runtime, count(*) - count(DISTINCT (session_id, message_id))
  FROM messages GROUP BY runtime
  UNION ALL
  SELECT 'api_calls', runtime, count(*) - count(DISTINCT (session_id, message_id))
  FROM api_calls GROUP BY runtime
  UNION ALL
  SELECT 'tool_calls', runtime, count(*) - count(DISTINCT (session_id, tool_use_id))
  FROM tool_calls GROUP BY runtime
)
SELECT tbl || ' has ' || n || ' repeated key row(s) for ' || runtime || '; fix the adapter so each key appears once' AS action
FROM dup WHERE n > 0
ORDER BY tbl, runtime;
