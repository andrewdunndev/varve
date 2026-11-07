-- QUESTION: What are the content-free SHAPE distributions of real sessions -- the
--   parameters any future synthetic benchmark must match to look like real work?
-- METRIC: Per (estate, runtime), distributions over structural features only.
--   Per-session intermediate: n_turns = count of user-role messages; n_api_calls =
--   count of api_calls; n_tool_calls = count of tool_calls; wall_min = message
--   span (last-first)/60; and the effective-context (input+cache_read) trajectory --
--   eff_start = eff of the session's first call (max among ties at the earliest
--   timestamp, so it is order-independent), eff_median = per-session median eff,
--   eff_peak = per-session max eff. Result sets:
--     (1) shape: p50/p90/max of turns, api_calls, tool_calls, wall_min.
--     (2) trajectory: p50/p90/max of eff_start / eff_median / eff_peak.
--     (3) tool-name mix: share of tool_calls by tool_name (NAMES ONLY -- instrument
--         metadata, not content; case/vocabulary differs by runtime, left verbatim).
--     (4) model-tier mix: call_share and cost_share by tier (model_economics.sql
--         tiering: opus/fable/sonnet/haiku/other).
--     (5) sidechain share (Claude Code only): call and cost share carried by
--         is_sidechain traffic, per estate.
-- THIS IS THE W6 v2 INPUT. Benchmark synthesis would derive synthetic task shapes
--   from exactly these distributions. v2 GENERATION STAYS GATED on its open questions
--   (abstraction fidelity vs leak risk, audit procedure, sufficient feature set) --
--   this query only produces the priors; it generates nothing.
-- CAVEATS: ZERO content -- no message text, no cwd, no session_id leaves this query;
--   every row is an aggregate over estate/runtime (+ tool_name or tier). A "turn" =
--   one operator (user) message; assistant/tool turns are not counted as turns.
--   wall_min includes idle gaps (session_shape.sql caveat). eff is per-call context,
--   not the UI counter. All aggregates are order-independent (quantile_cont, max,
--   sum) so the output is deterministic. TEMP table is in-memory (read-only safe).
-- W6 v1. Run: just sql -f queries/design_priors.sql
CREATE TEMP TABLE per_session AS
  WITH eff_base AS (
    SELECT session_id,
           (input + cache_read)                                     AS eff,
           timestamp,
           min(timestamp) OVER (PARTITION BY session_id)            AS first_ts
    FROM api_calls
  ),
  eff_stats AS (
    SELECT session_id,
           count(*)                                                 AS n_api_calls,
           max(eff) FILTER (WHERE timestamp = first_ts)             AS eff_start,
           quantile_cont(eff::double, 0.5)                          AS eff_median,
           max(eff)                                                 AS eff_peak
    FROM eff_base GROUP BY session_id
  ),
  turns AS (
    SELECT session_id, count(*) AS n_turns
    FROM messages WHERE role = 'user' GROUP BY session_id
  ),
  tools AS (
    SELECT session_id, count(*) AS n_tool_calls
    FROM tool_calls GROUP BY session_id
  ),
  span AS (
    SELECT session_id, min(timestamp) AS first_ts, max(timestamp) AS last_ts
    FROM messages GROUP BY session_id
  )
  SELECT
    s.estate, s.runtime,
    coalesce(t.n_turns, 0)                                          AS n_turns,
    coalesce(e.n_api_calls, 0)                                      AS n_api_calls,
    coalesce(tc.n_tool_calls, 0)                                    AS n_tool_calls,
    round(date_diff('second', sp.first_ts, sp.last_ts) / 60.0, 1)   AS wall_min,
    e.eff_start, e.eff_median, e.eff_peak
  FROM sessions s
  LEFT JOIN eff_stats e USING (session_id)
  LEFT JOIN turns     t USING (session_id)
  LEFT JOIN tools     tc USING (session_id)
  LEFT JOIN span      sp USING (session_id);

-- (1) session-shape distributions
SELECT
  estate, runtime,
  count(*)                                                          AS sessions,
  round(quantile_cont(n_turns::double, 0.5), 0)                     AS turns_p50,
  round(quantile_cont(n_turns::double, 0.9), 0)                     AS turns_p90,
  max(n_turns)                                                      AS turns_max,
  round(quantile_cont(n_api_calls::double, 0.5), 0)                 AS api_calls_p50,
  round(quantile_cont(n_api_calls::double, 0.9), 0)                 AS api_calls_p90,
  max(n_api_calls)                                                  AS api_calls_max,
  round(quantile_cont(n_tool_calls::double, 0.5), 0)                AS tool_calls_p50,
  round(quantile_cont(n_tool_calls::double, 0.9), 0)                AS tool_calls_p90,
  max(n_tool_calls)                                                 AS tool_calls_max,
  round(quantile_cont(wall_min::double, 0.5), 1)                    AS wall_min_p50,
  round(quantile_cont(wall_min::double, 0.9), 1)                    AS wall_min_p90,
  round(max(wall_min), 1)                                           AS wall_min_max
FROM per_session
GROUP BY ALL
ORDER BY estate, runtime;

-- (2) effective-context trajectory distributions (start / median / peak per session)
SELECT
  estate, runtime,
  count(*) FILTER (WHERE eff_peak IS NOT NULL)                      AS sessions_with_calls,
  round(quantile_cont(eff_start::double, 0.5), 0)                   AS start_p50,
  round(quantile_cont(eff_start::double, 0.9), 0)                   AS start_p90,
  max(eff_start)                                                    AS start_max,
  round(quantile_cont(eff_median::double, 0.5), 0)                  AS median_p50,
  round(quantile_cont(eff_median::double, 0.9), 0)                  AS median_p90,
  round(max(eff_median), 0)                                         AS median_max,
  round(quantile_cont(eff_peak::double, 0.5), 0)                    AS peak_p50,
  round(quantile_cont(eff_peak::double, 0.9), 0)                    AS peak_p90,
  max(eff_peak)                                                     AS peak_max
FROM per_session
GROUP BY ALL
ORDER BY estate, runtime;

-- (3) tool-name mix shares (names are instrument metadata, not content). Explicit
--   GROUP BY (not GROUP BY ALL): the share is a window over the group aggregate.
SELECT
  s.estate, tc.runtime,
  tc.tool_name,
  count(*)                                                          AS tool_calls,
  round(count(*) / sum(count(*)) OVER (PARTITION BY s.estate, tc.runtime), 4) AS share
FROM tool_calls tc
JOIN sessions s USING (session_id)
GROUP BY s.estate, tc.runtime, tc.tool_name
ORDER BY s.estate, tc.runtime, share DESC, tc.tool_name;

-- (4) model-tier mix by call share and cost share
WITH tiered AS (
  SELECT s.estate, a.runtime, a.cost_usd,
    CASE
      WHEN a.model LIKE 'claude-opus%'   THEN 'opus'
      WHEN a.model LIKE 'claude-fable%'  THEN 'fable'
      WHEN a.model LIKE 'claude-sonnet%' THEN 'sonnet'
      WHEN a.model LIKE 'claude-haiku%'  THEN 'haiku'
      ELSE 'other' END                                              AS tier
  FROM api_calls a JOIN sessions s USING (session_id)
)
SELECT
  estate, runtime, tier,
  count(*)                                                          AS calls,
  round(count(*) / sum(count(*)) OVER (PARTITION BY estate, runtime), 4)              AS call_share,
  round(sum(cost_usd), 2)                                           AS cost_usd,
  round(sum(cost_usd) / nullif(sum(sum(cost_usd)) OVER (PARTITION BY estate, runtime), 0), 4) AS cost_share
FROM tiered
GROUP BY estate, runtime, tier
ORDER BY estate, runtime, call_share DESC, tier;

-- (5) sidechain share, Claude Code only (dispatch structure)
SELECT
  s.estate,
  count(*)                                                          AS calls,
  round(count(*) FILTER (WHERE coalesce(m.is_sidechain, false)) / count(*)::double, 4) AS sidechain_call_share,
  round(sum(a.cost_usd) FILTER (WHERE coalesce(m.is_sidechain, false))
      / nullif(sum(a.cost_usd), 0), 4)                              AS sidechain_cost_share
FROM api_calls a
JOIN sessions s USING (session_id)
LEFT JOIN messages m ON m.session_id = a.session_id AND m.message_id = a.message_id
WHERE a.runtime = 'claude-code'
GROUP BY ALL
ORDER BY s.estate;
