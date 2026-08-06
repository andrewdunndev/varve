-- pi inline-cost vs computed-cost reconciliation (W2, ADR-0006). pi records an
-- inline-computed cost per assistant message; the adapter stores that as cost_usd
-- (preferring the runtime's inline value, RFC-0001). This query recomputes cost
-- from the stored tokens x the pricing seed and reports the per-model delta where
-- the model overlaps the seed -- so a divergence between pi's inline cost and our
-- seed is visible without a second stored column. Empty until a pi corpus exists.
-- Run: just recon-pi
WITH seed AS (
  SELECT * FROM read_csv(getvariable('repo') || '/adapters/pricing.csv',
    header = true, comment = '#', auto_detect = true)
),
pi AS (
  SELECT model,
         count(*)                 AS calls,
         sum(input)               AS input,
         sum(output)              AS output,
         sum(cache_read)          AS cache_read,
         sum(cache_write)         AS cache_write,
         round(sum(cost_usd), 4)  AS inline_cost,
         bool_or(unpriced_model)  AS any_unpriced
  FROM api_calls WHERE runtime = 'pi'
  GROUP BY model
)
SELECT
  pi.model,
  pi.calls,
  pi.inline_cost,
  round(
      pi.input       * coalesce(s.input_cost,0)
    + pi.output      * coalesce(s.output_cost,0)
    + pi.cache_read  * coalesce(s.cache_read_cost,0)
    + pi.cache_write * coalesce(s.cache_creation_cost,0), 4)      AS computed_cost,
  round(pi.inline_cost - (
      pi.input       * coalesce(s.input_cost,0)
    + pi.output      * coalesce(s.output_cost,0)
    + pi.cache_read  * coalesce(s.cache_read_cost,0)
    + pi.cache_write * coalesce(s.cache_creation_cost,0)), 4)     AS delta,
  pi.any_unpriced
FROM pi LEFT JOIN seed s ON pi.model = s.model
ORDER BY abs(coalesce(delta,0)) DESC;
