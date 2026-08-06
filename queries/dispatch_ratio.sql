-- QUESTION: Coordinate-by-default adherence -- what share of a session's work
--   (api_calls, tokens, cost) is carried by SUBAGENT traffic vs the main thread?
-- METRIC: A "dispatch unit" is one claude-code session. A call is SUBAGENT traffic
--   if its message has is_sidechain = true. Per unit: share_calls / share_tokens /
--   share_cost = subagent_X / total_X, where tokens = input+output+cache_read+
--   cache_write (all four classes). Weekly trend = same shares aggregated over
--   date_trunc('week', timestamp). FAT INLINE flag = units with total cost >=
--   threshold and ZERO subagent traffic. Threshold defaults to $20; override with:
--     just sql -c "SET VARIABLE fat_threshold='50'" -f queries/dispatch_ratio.sql
-- SCOPE: claude-code ONLY (coordinator decision 2026-07-06). opencode's
--   parent_session_id is a session-CHAIN link, not subagent dispatch -- 1318/1626
--   of its sessions are children yet carry ~6% of its priced cost, and the true
--   `agent` marker is populated on 2 rows -- so including it measured chaining,
--   not coordinate-by-default. pi has no sidechain and empty child linkage
--   (upstream gap): no dispatch signal there either. Revisit if either runtime
--   grows a real dispatch marker.
-- CAVEATS: tokens is cache_read-dominated, so share_tokens tracks cache reuse more
--   than work volume; share_cost is the load-bearing number.
-- The two TEMP tables are in-memory (no lake write; read-only safe) so the three
-- result sets below can share the classification without recomputing it.
-- W5. Run: just sql -f queries/dispatch_ratio.sql
CREATE TEMP TABLE call_role AS
  SELECT
    a.runtime,
    a.session_id                                                    AS dispatch_unit,
    coalesce(m.is_sidechain, false)                                 AS is_subagent,
    a.timestamp,
    a.cost_usd,
    (a.input + a.output + a.cache_read + a.cache_write)             AS tokens
  FROM api_calls a
  LEFT JOIN messages m
    ON m.session_id = a.session_id
   AND m.message_id = a.message_id
  WHERE a.runtime = 'claude-code';

CREATE TEMP TABLE per_unit AS
  SELECT
    dispatch_unit,
    any_value(runtime)                                             AS runtime,
    count(*)                                                       AS calls,
    count(*) FILTER (WHERE is_subagent)                            AS sub_calls,
    sum(tokens)                                                    AS tokens,
    coalesce(sum(tokens)   FILTER (WHERE is_subagent), 0)          AS sub_tokens,
    sum(cost_usd)                                                  AS cost,
    coalesce(sum(cost_usd) FILTER (WHERE is_subagent), 0)          AS sub_cost
  FROM call_role
  GROUP BY dispatch_unit;

-- (1) per-session (dispatch-unit) rows
SELECT
  u.dispatch_unit,
  u.runtime,
  s.estate,
  s.harness,
  s.campaign,
  u.calls,
  round(u.sub_calls  / nullif(u.calls, 0),  4)                     AS share_calls,
  round(u.sub_tokens / nullif(u.tokens, 0), 4)                     AS share_tokens,
  round(u.cost, 2)                                                 AS cost_usd,
  round(u.sub_cost / nullif(u.cost, 0), 4)                         AS share_cost
FROM per_unit u
LEFT JOIN sessions s ON s.session_id = u.dispatch_unit
ORDER BY u.cost DESC;

-- (2) weekly dispatch trend (cost/call/token share carried by subagents)
SELECT
  date_trunc('week', timestamp)::date                              AS week,
  runtime,
  count(*)                                                         AS calls,
  round(count(*) FILTER (WHERE is_subagent) / nullif(count(*), 0), 4)      AS share_calls,
  round(sum(tokens) FILTER (WHERE is_subagent) / nullif(sum(tokens), 0), 4) AS share_tokens,
  round(sum(cost_usd), 2)                                          AS cost_usd,
  round(sum(cost_usd) FILTER (WHERE is_subagent) / nullif(sum(cost_usd), 0), 4) AS share_cost
FROM call_role
GROUP BY ALL
ORDER BY week DESC, runtime;

-- (3) FAT INLINE candidates: expensive units with zero dispatch
SELECT
  u.dispatch_unit,
  u.runtime,
  s.estate,
  s.harness,
  s.campaign,
  u.calls,
  round(u.cost, 2)                                                 AS cost_usd
FROM per_unit u
LEFT JOIN sessions s ON s.session_id = u.dispatch_unit
WHERE u.sub_cost = 0
  AND u.cost >= coalesce(try_cast(getvariable('fat_threshold') AS DOUBLE), 20)
ORDER BY u.cost DESC;
