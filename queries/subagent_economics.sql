-- QUESTION: For Claude Code specifically, what do subagents (sidechain traffic)
--   cost vs the main thread over time -- is the coordinate-by-default posture
--   actually cheap, or is it moving real spend?
-- METRIC: claude-code only. A call is sidechain if its message has is_sidechain=true
--   (api_calls JOIN messages on session_id+message_id). Per week
--   (date_trunc('week', timestamp)): main_cost / sub_cost = sum(cost_usd) by role;
--   sub_cost_share = sub_cost / total; sub_call_share likewise; tokens = sum of all
--   four token classes by role. A totals row (week = NULL via ROLLUP) closes it.
-- PRIOR ART: W1's first recorded result -- cache_read outnumbers fresh input ~2000:1
--   on the primary model (cost structure is cache-read-dominated). This query carries
--   the same cache_read:input ratio per role so that result is visible per week.
-- CAVEATS: claude-code sidechain is the CLEAN dispatch signal (subagents write real
--   transcripts under <session>/subagents/, RFC-0001); opencode/pi are excluded here
--   (opencode chains sessions, pi writes no child transcript). "Savings" is a
--   comparison of where cost lands, not a counterfactual -- re-pricing the same work
--   inline is W6's job.
-- W5. Run: just sql -f queries/subagent_economics.sql
WITH cc AS (
  SELECT
    date_trunc('week', a.timestamp)::date                         AS week,
    coalesce(m.is_sidechain, false)                               AS is_sub,
    a.input, a.cache_read, a.cost_usd,
    (a.input + a.output + a.cache_read + a.cache_write)           AS tokens
  FROM api_calls a
  JOIN messages m
    ON m.session_id = a.session_id AND m.message_id = a.message_id
  WHERE a.runtime = 'claude-code'
)
SELECT
  week,
  count(*)                                                        AS calls,
  round(count(*) FILTER (WHERE is_sub) / count(*)::double, 4)     AS sub_call_share,
  round(sum(cost_usd) FILTER (WHERE NOT is_sub), 2)               AS main_cost,
  round(sum(cost_usd) FILTER (WHERE is_sub), 2)                   AS sub_cost,
  round(sum(cost_usd) FILTER (WHERE is_sub) / nullif(sum(cost_usd), 0), 4) AS sub_cost_share,
  sum(tokens) FILTER (WHERE NOT is_sub)                           AS main_tokens,
  sum(tokens) FILTER (WHERE is_sub)                               AS sub_tokens,
  round(sum(cache_read) / nullif(sum(input), 0), 0)              AS cache_read_to_input
FROM cc
GROUP BY ROLLUP (week)
ORDER BY week DESC NULLS FIRST;
