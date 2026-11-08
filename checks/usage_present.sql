-- A runtime whose newest calls all carry zero tokens has lost its usage field.
-- Missing usage reads 0 by contract (ADR-0009), so only this check can see it.
-- It reads the newest 20 calls, not the newest days: a runtime last used for a
-- few failed calls has zero usage that is real.
CREATE VIEW IF NOT EXISTS api_calls AS SELECT NULL::VARCHAR AS runtime, NULL::DATE AS date, NULL::BIGINT AS input, NULL::BIGINT AS output, NULL::BIGINT AS cache_read, NULL::BIGINT AS cache_write WHERE false;
SELECT 'api_calls for ' || runtime || ': ' || count(*) || ' recent calls carry no tokens; a usage field moved, fix the adapter' AS action
FROM (SELECT *, row_number() OVER (PARTITION BY runtime ORDER BY date DESC) AS n FROM api_calls)
WHERE n <= 20
GROUP BY runtime
HAVING count(*) >= 3 AND sum(coalesce(input, 0) + coalesce(output, 0) + coalesce(cache_read, 0) + coalesce(cache_write, 0)) = 0
ORDER BY runtime;
