-- Rebuilds retained files from their lines and compares sha256 with the manifest.
-- One batch of at most cap source bytes. Variables: mdir, batch, cap.
-- Needs live.sql. Prints: ok, bad, batches.
CREATE TEMP TABLE bm AS
SELECT * FROM (SELECT *, floor((sum(bytes) OVER (ORDER BY rel_path) - 1) / getvariable('cap'))::INT AS b
               FROM read_parquet(getvariable('mdir') || '/manifest.parquet'))
WHERE b = getvariable('batch');
SET VARIABLE nb = (SELECT coalesce(max(b), -1) + 1
                   FROM (SELECT floor((sum(bytes) OVER (ORDER BY rel_path) - 1) / getvariable('cap'))::INT AS b
                         FROM read_parquet(getvariable('mdir') || '/manifest.parquet')));
SET VARIABLE rels = coalesce((SELECT list(rel_path) FROM bm), []::VARCHAR[]);
SET VARIABLE files = (SELECT list(path) FROM live);
CREATE TEMP TABLE r AS
SELECT rel_path, count(*) AS c, string_agg(line, E'\n' ORDER BY line_no) AS s
FROM read_parquet(getvariable('files'), hive_partitioning = false)
WHERE rel_path IN (SELECT unnest(getvariable('rels')))
GROUP BY 1;
SELECT count(*) FILTER (WHERE ok) AS ok, count(*) FILTER (WHERE NOT ok) AS bad, getvariable('nb') AS batches
FROM (SELECT coalesce(r.c, 0) = bm.lines
         AND sha256(coalesce(r.s, '') || CASE WHEN bm.lines > 0 THEN E'\n' ELSE '' END || coalesce(bm.tail, '')) = bm.sha256 AS ok
      FROM bm LEFT JOIN r USING (rel_path));
