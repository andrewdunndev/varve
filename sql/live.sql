-- Which files under a runtime's lines/ the committed manifest names.
-- Variables: mdir (the runtime's mirror folder, no trailing slash).
-- Needs mdir/manifest.parquet. Defines:
--   gen   the committed generation, from the manifest's key-value metadata
--   lf    every file under lines/: path, bucket, kind (c or d), g
--   live  per bucket the newest compacted file c-<g> with g <= gen, plus the
--         deltas d-<g> with that g < d <= gen
CREATE TEMP TABLE gen AS
SELECT coalesce(max(decode(value)::BIGINT), 0) AS g
FROM parquet_kv_metadata(getvariable('mdir') || '/manifest.parquet') WHERE decode(key) = 'gen';
CREATE TEMP TABLE lf AS
SELECT file AS path,
       nullif(regexp_extract(file, '/bucket=([^/]+)/[^/]+$', 1), '') AS bucket,
       nullif(regexp_extract(file, '/([cd])-[0-9]+(-[0-9]+)?\.parquet$', 1), '') AS kind,
       nullif(regexp_extract(file, '/[cd]-([0-9]+)(-[0-9]+)?\.parquet$', 1), '')::BIGINT AS g
FROM glob(getvariable('mdir') || '/lines/**');
CREATE TEMP TABLE live AS
WITH cmax AS (
  SELECT f.bucket, max(f.g) AS g FROM lf f CROSS JOIN gen WHERE f.kind = 'c' AND f.g <= gen.g GROUP BY f.bucket)
SELECT f.path, f.bucket, f.kind, f.g
FROM lf f CROSS JOIN gen LEFT JOIN cmax c ON c.bucket = f.bucket
WHERE f.bucket IS NOT NULL AND f.kind IS NOT NULL AND f.g <= gen.g
  AND ((f.kind = 'c' AND f.g = c.g) OR (f.kind = 'd' AND f.g > coalesce(c.g, -1)));
