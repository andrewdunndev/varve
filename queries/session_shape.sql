-- QUESTION: What is the shape of a typical session, and which sessions are the
--   expensive outliers?
-- METRIC: Per session_id: n_calls = count(api_calls); wall_min = date_diff('second',
--   min(timestamp), max(timestamp))/60 over the session's MESSAGES (last-first);
--   cost_usd = sum(cost_usd). Distribution result: per (estate, runtime), p50/p90/max
--   of each of the three. Leaderboard: top 20 sessions by cost_usd with
--   estate/harness/campaign/runtime. Each opencode child session is its own session
--   here (per-session, not dispatch-unit).
-- CAVEATS: wall duration is derived from message timestamps and includes idle gaps
--   (a session left open overnight inflates wall) -- it is elapsed time, not active
--   time. Cost/calls come from api_calls, wall from messages, joined per session; a
--   session with messages but no priced calls shows cost 0. TEMP table is in-memory
--   (no lake write; read-only safe).
-- W5. Run: just sql -f queries/session_shape.sql
CREATE TEMP TABLE per_session AS
  SELECT
    s.session_id, s.runtime, s.estate, s.harness, s.campaign,
    coalesce(c.n_calls, 0)                                        AS n_calls,
    round(coalesce(c.cost, 0), 2)                                 AS cost_usd,
    round(date_diff('second', m.first_ts, m.last_ts) / 60.0, 1)   AS wall_min
  FROM sessions s
  LEFT JOIN (SELECT session_id, count(*) AS n_calls, sum(cost_usd) AS cost
             FROM api_calls GROUP BY 1) c USING (session_id)
  LEFT JOIN (SELECT session_id, min(timestamp) AS first_ts, max(timestamp) AS last_ts
             FROM messages GROUP BY 1) m USING (session_id);

-- (1) per-(estate, runtime) session-shape percentiles
SELECT
  estate, runtime,
  count(*)                                                        AS sessions,
  round(quantile_cont(n_calls::double, 0.5), 0)                   AS calls_p50,
  round(quantile_cont(n_calls::double, 0.9), 0)                   AS calls_p90,
  max(n_calls)                                                    AS calls_max,
  round(quantile_cont(wall_min::double, 0.5), 1)                  AS wall_min_p50,
  round(quantile_cont(wall_min::double, 0.9), 1)                  AS wall_min_p90,
  round(max(wall_min), 1)                                         AS wall_min_max,
  round(quantile_cont(cost_usd::double, 0.5), 2)                  AS cost_p50,
  round(quantile_cont(cost_usd::double, 0.9), 2)                  AS cost_p90,
  round(max(cost_usd), 2)                                         AS cost_max
FROM per_session
GROUP BY ALL
ORDER BY estate, runtime;

-- (2) expensive-session leaderboard (top 20 by cost)
SELECT
  session_id, runtime, estate, harness, campaign,
  n_calls, wall_min, cost_usd
FROM per_session
ORDER BY cost_usd DESC
LIMIT 20;
