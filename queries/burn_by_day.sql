-- QUESTION: Where does spend and token burn go, sliced by estate / harness /
--   campaign / model / day?
-- METRIC: Per (estate, harness, campaign, model, day): count(api_calls) AS calls;
--   sum of each token class (input, output, cache_read, cache_write); sum(cost_usd)
--   AS cost_usd. Day = api_calls.timestamp::date (the ROW timestamp, not the
--   session-start partition key), so a session spanning midnight lands on the right
--   day. estate/harness/campaign come from the joined sessions row (ingest-time
--   cwd attribution, ADR-0005).
-- CAVEATS: cost_usd is computed from tokens x pricing seed (costUSD absent from the
--   corpus, RFC-0001); console is authoritative. opencode subscription-billed
--   models (no per-token price) are $0 (unpriced) and contribute calls/tokens but no cost.
-- W5 table stakes; W1 acceptance. Run: just sql -f queries/burn_by_day.sql.
SELECT
  s.estate,
  s.harness,
  s.campaign,
  a.model,
  a.timestamp::date                       AS day,
  count(*)                                AS calls,
  sum(a.input)                            AS input,
  sum(a.output)                           AS output,
  sum(a.cache_read)                       AS cache_read,
  sum(a.cache_write)                      AS cache_write,
  round(sum(a.cost_usd), 2)               AS cost_usd
FROM api_calls a
JOIN sessions s USING (session_id)
GROUP BY ALL
ORDER BY day DESC, cost_usd DESC;
