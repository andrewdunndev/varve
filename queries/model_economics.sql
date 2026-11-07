-- QUESTION: What does each model cost per session and how cache-efficient is it,
--   and which harnesses/campaigns already run cheap vs which never leave opus?
-- METRIC: Per model: sessions = count(distinct session_id); calls; cost_usd;
--   cost_per_session = cost_usd / sessions; avg_cost_per_call; cache_hit_ratio =
--   sum(cache_read)/nullif(sum(cache_read)+sum(input),0). Clustering result: per
--   (harness, campaign): opus_cost_share = opus cost / total cost; cheap_call_share =
--   calls on sonnet-or-haiku / total calls. Tier by model-name prefix: opus, fable,
--   sonnet, haiku, else other; "cheap" = sonnet or haiku.
-- CAVEATS: fable-5 is priced ABOVE opus in the seed, so it is tier 'fable', not
--   cheap. Subscription-billed models (no per-token price, cost 0) land in 'other'
--   and depress cost shares without being a per-token cost decision, so a campaign
--   heavy in them reads as low opus_cost_share for free reasons; read
--   cheap_call_share (which counts them out) alongside.
--   cost_per_session mixes multi-model sessions (a session using opus and
--   haiku counts toward both). Console authoritative on absolute cost. TEMP table is
--   in-memory (no lake write; read-only safe).
-- Run: just sql -f queries/model_economics.sql
CREATE TEMP TABLE tiered AS
  SELECT a.*,
    CASE
      WHEN model LIKE 'claude-opus%'   THEN 'opus'
      WHEN model LIKE 'claude-fable%'  THEN 'fable'
      WHEN model LIKE 'claude-sonnet%' THEN 'sonnet'
      WHEN model LIKE 'claude-haiku%'  THEN 'haiku'
      ELSE 'other' END                                            AS tier
  FROM api_calls a;

-- (1) per-model economics + cache efficiency
SELECT
  model,
  any_value(tier)                                                 AS tier,
  count(DISTINCT session_id)                                      AS sessions,
  count(*)                                                        AS calls,
  round(sum(cost_usd), 2)                                         AS cost_usd,
  round(sum(cost_usd) / nullif(count(DISTINCT session_id), 0), 2) AS cost_per_session,
  round(sum(cost_usd) / nullif(count(*), 0), 4)                   AS avg_cost_per_call,
  round(sum(cache_read) / nullif(sum(cache_read)+sum(input), 0), 4) AS cache_hit_ratio
FROM tiered
GROUP BY model
ORDER BY cost_usd DESC;

-- (2) cheap-vs-opus clustering by harness / campaign
SELECT
  s.harness,
  s.campaign,
  count(*)                                                        AS calls,
  round(sum(t.cost_usd), 2)                                       AS cost_usd,
  round(sum(t.cost_usd) FILTER (WHERE t.tier = 'opus') / nullif(sum(t.cost_usd), 0), 4)  AS opus_cost_share,
  round(count(*) FILTER (WHERE t.tier IN ('sonnet','haiku')) / count(*)::double, 4)      AS cheap_call_share
FROM tiered t
JOIN sessions s USING (session_id)
GROUP BY ALL
HAVING sum(t.cost_usd) > 1
ORDER BY cost_usd DESC;
