-- No row is dated more than a day after the check runs (dates are UTC, the clock may be local).
CREATE VIEW IF NOT EXISTS sessions AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::DATE AS date WHERE false;
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::DATE AS date WHERE false;
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::DATE AS date WHERE false;
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS session_id, NULL::VARCHAR AS runtime, NULL::DATE AS date WHERE false;
WITH d AS (
  SELECT 'sessions' AS tbl, runtime, date FROM sessions
  UNION ALL SELECT 'messages', runtime, date FROM messages
  UNION ALL SELECT 'api_calls', runtime, date FROM api_calls
  UNION ALL SELECT 'tool_calls', runtime, date FROM tool_calls
)
SELECT tbl || ' has ' || count(*) || ' row(s) for ' || runtime || ' dated after today, latest ' || max(date) || '; fix the adapter''s timestamp parse' AS action
FROM d WHERE try_cast(date AS DATE) > current_date + 1
GROUP BY tbl, runtime
ORDER BY tbl, runtime;
