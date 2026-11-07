-- QUESTION: How do tool calls end, by tool? Which tools are refused, interrupted or
--   failing, and how much do their arguments and results weigh?
-- METRIC: Per (runtime, tool_name): calls, and the count of each
--   outcome (ok, error, denied, cancelled, running, none = the source recorded no
--   result). error_share = error / calls with a result. arg_chars and result_chars
--   are the average length of arguments and result_text over rows that have them.
-- SCOPE: every runtime. A Claude Code result with no tool_use has a NULL tool_name
--   and counts under it. pi records only ok and error.
-- Run: just sql -f queries/tool_outcomes.sql
SELECT
  runtime,
  tool_name,
  count(*)                                                             AS calls,
  count(*) FILTER (WHERE outcome = 'ok')                               AS ok,
  count(*) FILTER (WHERE outcome = 'error')                            AS error,
  count(*) FILTER (WHERE outcome = 'denied')                           AS denied,
  count(*) FILTER (WHERE outcome = 'cancelled')                        AS cancelled,
  count(*) FILTER (WHERE outcome = 'running')                          AS running,
  count(*) FILTER (WHERE outcome IS NULL)                              AS none,
  round(count(*) FILTER (WHERE outcome = 'error')::double
        / nullif(count(*) FILTER (WHERE outcome IS NOT NULL), 0), 3)   AS error_share,
  round(avg(length(arguments)), 1)                                     AS arg_chars,
  round(avg(length(result_text)), 1)                                   AS result_chars
FROM tool_calls
GROUP BY runtime, tool_name
ORDER BY runtime, calls DESC, tool_name;
