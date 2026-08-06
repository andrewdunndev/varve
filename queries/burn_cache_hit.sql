-- QUESTION: How cache-read-dominated is the burn -- what fraction of attended
--   input tokens are served from cache rather than fresh, by model and by day?
-- METRIC: cache_hit_ratio = sum(cache_read) / nullif(sum(cache_read)+sum(input), 0).
--   Reported (1) per model and (2) per day (all models). Also emits the raw token
--   sums and the cache_read:input ratio (sum(cache_read)/nullif(sum(input),0)) that
--   W1's "~2000:1" result is stated in.
-- CAVEATS: Denominator is cache_read + input only -- cache_write (cache CREATION)
--   is excluded, so this measures read-reuse vs fresh input, NOT creation overhead.
--   A high ratio is the recycle-discipline signal (the model re-attends a large
--   cached prefix); it is not per se waste, but pairs with recycle.sql (redline tax)
--   to separate healthy caching from context that should have been recycled.
-- W5 burn family. Run: just sql -f queries/burn_cache_hit.sql

-- (1) by model
SELECT
  model,
  count(*)                                              AS calls,
  sum(input)                                            AS input,
  sum(cache_read)                                       AS cache_read,
  round(sum(cache_read) / nullif(sum(cache_read)+sum(input), 0), 4) AS cache_hit_ratio,
  round(sum(cache_read) / nullif(sum(input), 0), 0)     AS cache_read_to_input
FROM api_calls
GROUP BY ALL
ORDER BY cache_read DESC;

-- (2) by day (all models)
SELECT
  timestamp::date                                       AS day,
  count(*)                                              AS calls,
  sum(input)                                            AS input,
  sum(cache_read)                                       AS cache_read,
  round(sum(cache_read) / nullif(sum(cache_read)+sum(input), 0), 4) AS cache_hit_ratio
FROM api_calls
GROUP BY ALL
ORDER BY day DESC;
