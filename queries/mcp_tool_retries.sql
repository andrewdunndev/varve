-- QUESTION: How often do MCP tool calls fail across servers and tools, and how often
--   do agents enter retry loops (repeated calls after failure, including resubmitting
--   the exact same arguments)?
-- METRIC:
--   1. MCP server error and permission-denial rates
--   2. Tool-level error profiles (tools with >= 3 calls)
--   3. Retry sequences: sequences of calls to the same tool within a session,
--      tracking recoveries, repeated failures, and identical argument resubmissions
--      (stuck loop indicator).
-- CAVEATS: Reads mcp_server / mcp_tool columns (populated by the Copilot adapter;
--   falls back to prefix-parsed tool_name for other runtimes).
-- Usage: just sql -f queries/mcp_tool_retries.sql

CREATE OR REPLACE TEMP VIEW _mcp_calls AS
SELECT
  runtime,
  session_id,
  started_at,
  coalesce(mcp_server, regexp_extract(tool_name, '^([^-_]+)[-_]', 1), 'default') AS server,
  coalesce(mcp_tool, regexp_replace(tool_name, '^[^-_]+[-_]', ''), tool_name)     AS tool,
  decision,
  error_code,
  error_message,
  arguments,
  md5(coalesce(arguments, '')) AS args_hash
FROM tool_calls
WHERE mcp_server IS NOT NULL OR mcp_tool IS NOT NULL OR runtime = 'copilot';

-- (1) Per-server failure & denial profile
SELECT
  server,
  count(*)                                                                     AS total_calls,
  count(*) FILTER (WHERE decision = 'completed')                               AS success_calls,
  count(*) FILTER (WHERE decision = 'error')                                   AS error_calls,
  count(*) FILTER (WHERE decision = 'denied')                                  AS denied_calls,
  round(100.0 * count(*) FILTER (WHERE decision = 'error') / count(*), 1)      AS error_pct,
  round(100.0 * count(*) FILTER (WHERE decision = 'denied') / count(*), 1)     AS denial_pct
FROM _mcp_calls
GROUP BY ALL
ORDER BY total_calls DESC;

-- (2) Per server x tool failure ranking (tools with >= 3 calls, worst error rates first)
SELECT
  server,
  tool,
  count(*)                                                                     AS total_calls,
  count(*) FILTER (WHERE decision = 'error')                                   AS error_calls,
  count(*) FILTER (WHERE decision = 'denied')                                  AS denied_calls,
  round(100.0 * count(*) FILTER (WHERE decision = 'error') / count(*), 1)      AS error_pct
FROM _mcp_calls
GROUP BY ALL
HAVING count(*) >= 3
ORDER BY error_calls DESC, total_calls DESC
LIMIT 30;

-- (3) Retry sequences & defective argument resubmission loops
WITH seq AS (
  SELECT
    session_id,
    server,
    tool,
    started_at,
    decision,
    error_message,
    args_hash,
    lag(decision) OVER w                                                       AS prev_decision,
    lag(args_hash) OVER w                                                      AS prev_args_hash,
    lag(error_message) OVER w                                                  AS prev_error,
    row_number() OVER w                                                        AS seq_no
  FROM _mcp_calls
  WINDOW w AS (PARTITION BY session_id, server, tool ORDER BY started_at)
)
SELECT
  server,
  tool,
  count(*)                                                                     AS total_retries,
  count(*) FILTER (WHERE prev_decision = 'error' AND decision = 'completed')   AS recovered,
  count(*) FILTER (WHERE prev_decision = 'error' AND decision = 'error')       AS repeated_errors,
  count(*) FILTER (WHERE prev_decision = 'error' AND args_hash = prev_args_hash AND args_hash <> md5('')) AS resubmitted_same_args
FROM seq
WHERE prev_decision IS NOT NULL
GROUP BY ALL
ORDER BY repeated_errors DESC, total_retries DESC
LIMIT 30;
