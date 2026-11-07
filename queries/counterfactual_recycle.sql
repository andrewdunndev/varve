-- QUESTION: What could the redline tax have been worth? For every call whose
--   effective context ran over the recycle threshold, model the cost had context
--   been held AT the threshold, and report the gap vs actual by estate/month.
-- METRIC: effective context/call = input + cache_read (the recycle.sql definition).
--   For a call with eff > t, the EXCESS = eff - t is repriced to zero. The saved
--   cost is the attended-context cost of that excess: ctx_cost = input*input_rate +
--   cache_read*cache_read_rate (at the call's OWN model rates, from pricing.csv --
--   output and cache_write are untouched), scaled by the excess fraction:
--     saving = ctx_cost * (eff - t) / eff       (0 when eff <= t).
--   This allocates the excess across input and cache_read in their existing per-call
--   mix (proportional), which is exactly ctx_cost held at t/eff. Counterfactual cost
--   = actual cost_usd - saving. Reported (1) per estate x month and (2) as a total
--   with saving as a share of TOTAL priced spend. Hold threshold defaults to 120000
--   (recycle.sql's redline); override with
--     just sql -c "SET VARIABLE t1='180000'" -f queries/counterfactual_recycle.sql
-- ASSUMPTIONS (this is an UPPER BOUND, not a target):
--   * It does NOT model the re-orientation cost of recycling -- a fresh session must
--     re-read the context it dropped, and that re-read is not free.
--   * It does NOT model output-token changes -- output and cache_write cost are held
--     fixed; only the input+cache_read excess is repriced.
--   * It assumes work quality is unaffected by running leaner.
--   Turning this bound into an achievable target is a separate, benchmark question.
-- CAVEATS: PER-CALL context, not the harness UI counter (recycle.sql caveat). The
--   proportional excess allocation is a modeling choice: it prices the dropped tokens
--   at the call's blended input/cache_read mix, not cache_read-first. Rates come from
--   the seed (pricing.csv); Claude Code's stored cost_usd IS seed-computed so the
--   estate is fully consistent, while opencode's cost_usd is its own inline value --
--   a negligible inline-vs-seed drift rides into opencode's counterfactual. Unpriced
--   (subscription-billed, $0) calls contribute zero saving by construction, so redline_calls counts
--   PRICED calls over threshold only (they are what the saving is drawn from).
--   Console authoritative on absolute cost. TEMP table is in-memory (read-only safe).
-- W6 v1. Run: just sql -f queries/counterfactual_recycle.sql
CREATE TEMP TABLE per_call AS
  WITH thr AS (
    SELECT coalesce(try_cast(getvariable('t1') AS BIGINT), 120000) AS t
  ),
  price AS (
    SELECT model, input_cost, cache_read_cost
    FROM read_csv(coalesce(getvariable('repo'), '.') || '/adapters/pricing.csv',
                  header = true, comment = '#', auto_detect = true)
  )
  SELECT
    s.estate,
    date_trunc('month', a.timestamp)::date                          AS month,
    (a.input + a.cache_read)                                        AS eff,
    a.cost_usd,
    (a.input      * coalesce(p.input_cost, 0)
   + a.cache_read * coalesce(p.cache_read_cost, 0))                 AS ctx_cost,
    (SELECT t FROM thr)                                             AS t
  FROM api_calls a
  JOIN sessions s USING (runtime, session_id)
  LEFT JOIN price p USING (model);

-- (1) actual vs counterfactual by estate x month
SELECT
  estate,
  month,
  count(*) FILTER (WHERE eff > t AND cost_usd > 0)                  AS redline_calls,
  round(sum(cost_usd), 2)                                          AS actual_cost_usd,
  round(sum(cost_usd)
      - sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END), 2) AS counterfactual_cost_usd,
  round(sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END), 2) AS saving_usd,
  round(sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END)
      / nullif(sum(cost_usd), 0), 4)                               AS saving_share
FROM per_call
GROUP BY ALL
ORDER BY estate, month;

-- (2) total, with saving as a share of total priced spend
SELECT
  count(*) FILTER (WHERE eff > t AND cost_usd > 0)                  AS redline_calls,
  round(sum(cost_usd), 2)                                          AS actual_cost_usd,
  round(sum(cost_usd)
      - sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END), 2) AS counterfactual_cost_usd,
  round(sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END), 2) AS saving_usd,
  round(sum(CASE WHEN eff > t THEN ctx_cost * (eff - t) / eff::double ELSE 0 END)
      / nullif(sum(cost_usd), 0), 4)                               AS pct_of_total_spend
FROM per_call;
