-- No runtime may lose rows in any core table against the published lake, except
-- those of forgotten sessions. The count is net per runtime and table, not per
-- session: a re-parse may legitimately move rows between sessions. A surviving
-- session that loses messages or tool calls passes no_lost_sessions, so this
-- compares the counts.
CREATE VIEW IF NOT EXISTS forgotten AS SELECT NULL::VARCHAR AS session_id WHERE false;
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS published_sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS published_messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS published_api_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
CREATE VIEW IF NOT EXISTS published_tool_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime WHERE false;
WITH was AS (
  SELECT 'sessions' AS tbl, runtime, count(*) AS n FROM published_sessions WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
  UNION ALL
  SELECT 'messages', runtime, count(*) FROM published_messages WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
  UNION ALL
  SELECT 'api_calls', runtime, count(*) FROM published_api_calls WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
  UNION ALL
  SELECT 'tool_calls', runtime, count(*) FROM published_tool_calls WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
), cur AS (
  SELECT 'sessions' AS tbl, runtime, count(*) AS n FROM sessions WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
  UNION ALL
  SELECT 'messages', runtime, count(*) FROM messages WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
  UNION ALL
  SELECT 'api_calls', runtime, count(*) FROM api_calls WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
  UNION ALL
  SELECT 'tool_calls', runtime, count(*) FROM tool_calls WHERE session_id NOT IN (SELECT session_id FROM forgotten) GROUP BY runtime
)
SELECT w.tbl || ' rows for ' || w.runtime || ' fell from ' || w.n || ' to ' || coalesce(c.n, 0) || '; restore the mirror files or fix the adapter before the swap. If the new count is right, move the lake aside and rebuild, and keep the moved lake' AS action
FROM was w LEFT JOIN cur c USING (tbl, runtime)
WHERE coalesce(c.n, 0) < w.n
ORDER BY w.tbl, w.runtime;
