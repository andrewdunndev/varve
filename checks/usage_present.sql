-- A runtime whose recent calls all carry zero tokens has lost its usage field.
-- Missing usage reads 0 by contract (ADR-0009), so only this check can see it.
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS runtime, NULL::DATE AS date, NULL::BIGINT AS input, NULL::BIGINT AS output, NULL::BIGINT AS cache_read, NULL::BIGINT AS cache_write WHERE false;
SELECT 'api_calls for ' || runtime || ': ' || count(*) || ' recent calls carry no tokens; a usage field moved, fix the adapter' AS action
FROM (SELECT *, max(date) OVER (PARTITION BY runtime) AS newest FROM api_calls)
WHERE date > newest - 7
GROUP BY runtime
HAVING count(*) >= 3 AND sum(coalesce(input, 0) + coalesce(output, 0) + coalesce(cache_read, 0) + coalesce(cache_write, 0)) = 0
ORDER BY runtime;
