-- After live.sql: the generation, every file under lines/ the manifest does not
-- name, and the live delta count per bucket. Tab separated.
SELECT 'gen' AS k, g::VARCHAR AS a, '' AS b FROM gen
UNION ALL SELECT 'orphan', path, '' FROM lf WHERE path NOT IN (SELECT path FROM live)
UNION ALL SELECT 'deltas', bucket, count(*) FILTER (WHERE kind = 'd')::VARCHAR FROM live GROUP BY bucket;
