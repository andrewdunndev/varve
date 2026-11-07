-- Reconciliation vs ccusage (ADR-0006 denominator).
-- Emits varve's per-model token totals by class and computed cost. Compare
-- against `npx ccusage@latest daily --json --mode auto` summed over the SAME
-- Claude Code model ids. ccusage v20 is a MULTI-agent aggregator: it also reports
-- opencode / codex / gemini / subscription-billed usage (gpt-5, gemini-*, and
-- Claude models seen ONLY through other agents, e.g. claude-opus-4-6/4-5 which do
-- not appear in ~/.claude). This is Claude Code only, so reconcile model-for-model
-- against the ids that varve actually emits. Run: just sql -f queries/reconcile_ccusage.sql
SELECT
  model,
  count(*)             AS calls,
  sum(input)           AS input,
  sum(output)          AS output,
  sum(cache_read)      AS cache_read,
  sum(cache_write)     AS cache_write,
  round(sum(cost_usd), 2) AS cost_usd,
  bool_or(unpriced_model) AS any_unpriced
FROM api_calls
GROUP BY ROLLUP (model)
ORDER BY cost_usd DESC NULLS LAST;
