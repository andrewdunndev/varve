-- QUESTION: How often do MCP tool calls fail across servers and tools, and how often
--   do agents enter retry loops (repeated calls after failure, including resubmitting
--   the exact same arguments)?
-- METRIC:
--   1. MCP server failure and permission-denial rates
--   2. Tool-level error profiles (tools with >= 3 calls, ranked by failure count)
--   3. Retry sequences: consecutive calls to the same tool within a session,
--      tracking recoveries, repeated failures, and identical argument resubmissions
--      (stuck loop indicator).
-- CAVEATS: Reads mcp_server / mcp_tool columns (populated by the Copilot adapter;
--   falls back to prefix-parsed tool_name for other runtimes). Identifies failures
--   via runner decision ('error', 'rejected') as well as standard MCP payload flags
--   (isError = true, success = false).
-- Usage: just sql -f queries/mcp_tool_retries.sql

CREATE OR REPLACE TEMP VIEW _mcp_calls AS
SELECT
  runtime,
  session_id,
  started_at,
  coalesce(nullif(mcp_server, ''), nullif(regexp_extract(tool_name, '^([^-_]+)[-_]', 1), ''), 'core') AS server,
  coalesce(nullif(mcp_tool, ''), nullif(regexp_replace(tool_name, '^[^-_]+[-_]', ''), ''), tool_name)     AS tool,
  decision,
  CASE
    WHEN decision IN ('error', 'rejected') THEN true
    WHEN json_valid(result_text) AND (
      coalesce(try_cast(result_text::json->>'isError' AS boolean), false) = true OR
      coalesce(try_cast(result_text::json->>'success' AS boolean), true) = false OR
      coalesce(try_cast(result_text::json->'activation'->>'success' AS boolean), true) = false
    ) THEN true
    ELSE false
  END AS is_error,
  error_message,
  arguments,
  md5(coalesce(arguments, '')) AS args_hash
FROM tool_calls
WHERE mcp_server IS NOT NULL OR mcp_tool IS NOT NULL OR runtime = 'copilot';

-- (1) Per-server failure & denial profile
SELECT
  server,
  count(*)                                                                     AS total_calls,
  count(*) FILTER (WHERE NOT is_error AND decision <> 'denied')                AS success_calls,
  count(*) FILTER (WHERE is_error)                                             AS error_calls,
  count(*) FILTER (WHERE decision = 'denied')                                  AS denied_calls,
  round(100.0 * count(*) FILTER (WHERE is_error) / count(*), 1)                AS error_pct,
  round(100.0 * count(*) FILTER (WHERE decision = 'denied') / count(*), 1)     AS denial_pct
FROM _mcp_calls
GROUP BY ALL
ORDER BY total_calls DESC;

-- (2) Per server x tool failure ranking (tools with >= 3 calls, worst error rates first)
SELECT
  server,
  tool,
  count(*)                                                                     AS total_calls,
  count(*) FILTER (WHERE is_error)                                             AS error_calls,
  count(*) FILTER (WHERE decision = 'denied')                                  AS denied_calls,
  round(100.0 * count(*) FILTER (WHERE is_error) / count(*), 1)                AS error_pct
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
    is_error,
    args_hash,
    lag(is_error) OVER w                                                       AS prev_error,
    lag(args_hash) OVER w                                                      AS prev_args_hash
  FROM _mcp_calls
  WINDOW w AS (PARTITION BY session_id, server, tool ORDER BY started_at)
)
SELECT
  server,
  tool,
  count(*)                                                                     AS total_retries,
  count(*) FILTER (WHERE prev_error AND NOT is_error)                          AS recovered,
  count(*) FILTER (WHERE prev_error AND is_error)                              AS repeated_errors,
  count(*) FILTER (WHERE prev_error AND is_error AND args_hash = prev_args_hash AND args_hash <> md5('')) AS resubmitted_same_args
FROM seq
WHERE prev_error IS NOT NULL
GROUP BY ALL
ORDER BY repeated_errors DESC, total_retries DESC
LIMIT 30;
