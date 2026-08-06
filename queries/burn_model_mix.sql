-- QUESTION: How is each estate's weekly spend split across models -- is the
--   model mix shifting toward cheaper tiers over time?
-- METRIC: For each (estate, week, model): model_cost = sum(cost_usd); cost_share =
--   model_cost / sum(model_cost) OVER (estate, week). week = date_trunc('week',
--   timestamp) (Monday-start). estate from the joined sessions row.
-- CAVEATS: Share is of PRICED cost, so opencode GitLab-Duo ($0) rows carry calls
--   but drop out of the share denominator -- a week that is all-Duo shows near-zero
--   cost and an unstable share. Weeks with tiny total cost make shares noisy; read
--   alongside the week_total_cost column. Model tier economics differ (fable-5 is
--   priced ABOVE opus per RFC pricing seed), so "cheaper mix" is not "more non-opus".
-- W5 burn family. Run: just sql -f queries/burn_model_mix.sql
WITH per_model AS (
  SELECT
    s.estate,
    date_trunc('week', a.timestamp)::date AS week,
    a.model,
    sum(a.cost_usd)                       AS model_cost
  FROM api_calls a
  JOIN sessions s USING (session_id)
  GROUP BY ALL
)
SELECT
  estate,
  week,
  model,
  round(model_cost, 2)                                                        AS model_cost,
  round(sum(model_cost) OVER (PARTITION BY estate, week), 2)                   AS week_total_cost,
  round(model_cost / nullif(sum(model_cost) OVER (PARTITION BY estate, week), 0), 4) AS cost_share
FROM per_model
ORDER BY estate, week DESC, model_cost DESC;
