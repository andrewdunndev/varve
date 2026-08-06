-- QUESTION: What tier-routing headroom exists? Reprice structurally-identifiable
--   call classes at a cheaper tier's per-token rates and report the gap.
-- METRIC: Two STRUCTURAL Claude Code classes (the runtime with a real dispatch
--   marker, dispatch_ratio.sql):
--     (a) SIDECHAIN opus -> sonnet: calls whose message is_sidechain = true on an
--         opus-class model, repriced at sonnet-class rates. Sidechain work is
--         delegated-by-structure, the population coordinate-by-default targets.
--     (b) MAIN-THREAD fable -> opus: non-sidechain calls on the fable tier (priced
--         2x opus in the seed), repriced at opus-class rates -- premium-tier
--         de-escalation headroom.
--   Repriced cost of a class = sum over its calls of input*R.input + output*R.output
--   + cache_read*R.cache_read + cache_write*R.cache_creation, where R is the TARGET
--   tier's representative row read from pricing.csv the same way the adapters do
--   (sonnet-class = claude-sonnet-5; opus-class = claude-opus-4-8 -- the current
--   models of each tier). Per class: call count, actual cost_usd, repriced cost,
--   delta = actual - repriced, and delta as a share of total priced spend.
-- ASSUMPTIONS (this is HEADROOM, not a claim):
--   * Repricing assumes EQUAL token counts and EQUAL outcome quality -- it is the
--     price gap if the cheaper tier did the identical work, NOT a claim the cheaper
--     tier would succeed. Whether it does is a benchmark question, not this query's.
--   * The W5 finding that cheap tiers (sonnet+haiku) are ~0.7% of spend is the
--     ADOPTION BASELINE this headroom is measured against.
-- CAVEATS: Tier by model-name prefix (model_economics.sql convention); fable is a
--   tier of its own (priced ABOVE opus), so (b) is a genuine cheaper-tier reprice.
--   Claude Code only -- opencode's cost is inline and its dispatch marker is a
--   session chain, not delegation (dispatch_ratio.sql SCOPE note). Representative
--   target rates ignore intra-tier version spread (sonnet-5 vs sonnet-4-6). Console
--   authoritative on absolute cost. TEMP table is in-memory (no lake write;
--   read-only safe).
-- W6 v1. Run: just sql -f queries/counterfactual_tier.sql
CREATE TEMP TABLE cc_calls AS
  SELECT
    coalesce(m.is_sidechain, false)                                 AS is_subagent,
    CASE
      WHEN a.model LIKE 'claude-opus%'   THEN 'opus'
      WHEN a.model LIKE 'claude-fable%'  THEN 'fable'
      WHEN a.model LIKE 'claude-sonnet%' THEN 'sonnet'
      WHEN a.model LIKE 'claude-haiku%'  THEN 'haiku'
      ELSE 'other' END                                              AS tier,
    a.input, a.output, a.cache_read, a.cache_write, a.cost_usd
  FROM api_calls a
  LEFT JOIN messages m
    ON m.session_id = a.session_id
   AND m.message_id = a.message_id
  WHERE a.runtime = 'claude-code';

WITH price AS (
  SELECT model, input_cost, output_cost, cache_read_cost, cache_creation_cost
  FROM read_csv(coalesce(getvariable('repo'), '.') || '/adapters/pricing.csv',
                header = true, comment = '#', auto_detect = true)
),
son AS (SELECT * FROM price WHERE model = 'claude-sonnet-5'),
op  AS (SELECT * FROM price WHERE model = 'claude-opus-4-8'),
total AS (SELECT sum(cost_usd) AS spend FROM api_calls),
class AS (
  -- (a) sidechain opus repriced at sonnet-class
  SELECT
    'a: CC sidechain opus -> sonnet'                                AS class,
    count(*)                                                        AS calls,
    round(sum(cost_usd), 2)                                         AS actual_cost_usd,
    round(sum(input      * (SELECT input_cost FROM son)
           + output      * (SELECT output_cost FROM son)
           + cache_read  * (SELECT cache_read_cost FROM son)
           + cache_write * (SELECT cache_creation_cost FROM son)), 2) AS repriced_cost_usd
  FROM cc_calls WHERE is_subagent AND tier = 'opus'
  UNION ALL
  -- (b) main-thread fable repriced at opus-class
  SELECT
    'b: CC main-thread fable -> opus',
    count(*),
    round(sum(cost_usd), 2),
    round(sum(input      * (SELECT input_cost FROM op)
           + output      * (SELECT output_cost FROM op)
           + cache_read  * (SELECT cache_read_cost FROM op)
           + cache_write * (SELECT cache_creation_cost FROM op)), 2)
  FROM cc_calls WHERE NOT is_subagent AND tier = 'fable'
)
SELECT
  class,
  calls,
  actual_cost_usd,
  repriced_cost_usd,
  round(actual_cost_usd - repriced_cost_usd, 2)                     AS delta_usd,
  round((actual_cost_usd - repriced_cost_usd)
      / nullif((SELECT spend FROM total), 0), 4)                    AS delta_share_of_spend
FROM class
ORDER BY delta_usd DESC, class;
