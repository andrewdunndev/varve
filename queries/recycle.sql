-- QUESTION: Context discipline -- do sessions stay dense under the 120K/180K
--   recycle thresholds, or do calls run over them, and what does that cost?
-- METRIC: effective context per api_call = input + cache_read (the tokens the model
--   attends over). Per session: max_eff_ctx = max(input+cache_read);
--   pct_over_t1 / pct_over_t2 = share of that session's calls with
--   input+cache_read above each threshold; over_threshold_cost_usd = sum(cost_usd) of the
--   session's calls above 120K. Distribution result: per estate,
--   p50/p90/max of per-session max_eff_ctx, over_threshold_cost_usd summed, and over-threshold cost as
--   a share of estate cost. Thresholds default 120K/180K; override with
--     just sql -c "SET VARIABLE t1='100000'" -c "SET VARIABLE t2='160000'" -f queries/recycle.sql
-- CAVEATS: This is per-call context (input+cache_read), not the UI token
--   counter -- they differ (the UI shows a live working-set estimate). Close enough
--   for adherence TRENDS, not for exact UI parity. Note: opus-4-7/4-8 offer a 1M
--   window, so a call above 180K is not necessarily over a hard limit -- the
--   thresholds assume a 200K window, applied uniformly. TEMP
--   table is in-memory (no lake write; read-only safe).
-- Run: just sql -f queries/recycle.sql
CREATE TEMP TABLE per_session AS
  WITH thr AS (
    SELECT coalesce(try_cast(getvariable('t1') AS BIGINT), 120000) AS t1,
           coalesce(try_cast(getvariable('t2') AS BIGINT), 180000) AS t2
  ),
  calls AS (
    SELECT a.session_id, a.runtime, s.estate,
           (a.input + a.cache_read) AS eff, a.cost_usd,
           (SELECT t1 FROM thr) AS t1, (SELECT t2 FROM thr) AS t2
    FROM api_calls a JOIN sessions s USING (session_id)
  )
  SELECT
    session_id,
    any_value(runtime)                                          AS runtime,
    any_value(estate)                                           AS estate,
    count(*)                                                    AS calls,
    max(eff)                                                    AS max_eff_ctx,
    round(count(*) FILTER (WHERE eff > t1) / count(*)::double, 4) AS pct_over_t1,
    round(count(*) FILTER (WHERE eff > t2) / count(*)::double, 4) AS pct_over_t2,
    round(sum(cost_usd) FILTER (WHERE eff > t1), 2)             AS over_threshold_cost_usd,
    round(sum(cost_usd), 2)                                     AS cost_usd
  FROM calls GROUP BY session_id;

-- (1) per-session context discipline
SELECT * FROM per_session
ORDER BY over_threshold_cost_usd DESC NULLS LAST;

-- (2) distribution across sessions, by estate
SELECT
  estate,
  count(*)                                                      AS sessions,
  round(quantile_cont(max_eff_ctx::double, 0.5), 0)             AS p50_max_ctx,
  round(quantile_cont(max_eff_ctx::double, 0.9), 0)             AS p90_max_ctx,
  max(max_eff_ctx)                                              AS max_max_ctx,
  round(sum(over_threshold_cost_usd), 2)                               AS over_threshold_cost_usd,
  round(sum(over_threshold_cost_usd) / nullif(sum(cost_usd), 0), 4)    AS over_threshold_share
FROM per_session
GROUP BY ALL
ORDER BY over_threshold_cost_usd DESC;
