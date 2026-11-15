-- Rewrites one bucket as a single sorted file, level 19, and the next manifest.
-- Variables: mdir, bucket, drop (a session id whose files leave, or ''), alter
-- ('row' changes one output line, for the tests), out
-- (the new file's path under the staging folder), staging (its folder).
-- Placeholder @GEN@: the new generation. Needs live.sql. Fails, writing no
-- manifest, unless the rows and their hash equal the inputs and every file's
-- lines equal the manifest.
CREATE TEMP TABLE keep AS
SELECT * FROM read_parquet(getvariable('mdir') || '/manifest.parquet')
WHERE getvariable('drop') = '' OR NOT contains(rel_path, getvariable('drop'));
SET VARIABLE inputs = (SELECT list(path ORDER BY path) FROM live WHERE bucket = getvariable('bucket'));
CREATE TEMP TABLE inp AS
SELECT count(*) AS n, coalesce(sum(hash(rel_path, line_no, line)::HUGEINT), 0) AS h
FROM read_parquet(getvariable('inputs'), hive_partitioning = false)
WHERE getvariable('drop') = '' OR NOT contains(rel_path, getvariable('drop'));
COPY (SELECT rel_path, line_no, line || CASE WHEN getvariable('alter') = 'row' AND line_no = 1 THEN 'x' ELSE '' END AS line
      FROM read_parquet(getvariable('inputs'), hive_partitioning = false)
      WHERE getvariable('drop') = '' OR NOT contains(rel_path, getvariable('drop'))
      ORDER BY rel_path, line_no)
  TO (getvariable('out')) (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 19, ROW_GROUP_SIZE 20000, ROW_GROUP_SIZE_BYTES '64MB');
SELECT CASE WHEN (SELECT n FROM inp) = count(*) AND (SELECT h FROM inp) = coalesce(sum(hash(rel_path, line_no, line)::HUGEINT), 0)
            THEN 'rows and hash equal' ELSE error('compact: the rewritten bucket differs from its inputs') END AS rows_and_hash
FROM read_parquet(getvariable('out'));
SELECT CASE WHEN count(*) = 0 THEN 'lines equal the manifest'
            ELSE error('compact: ' || count(*) || ' files hold a line count the manifest does not') END AS per_file
FROM (SELECT rel_path, count(*) AS c, max(line_no) AS mx FROM read_parquet(getvariable('out')) GROUP BY 1) o
FULL JOIN (SELECT * FROM keep WHERE bucket = getvariable('bucket')) k USING (rel_path)
WHERE coalesce(o.c, 0) <> coalesce(k.lines, -1) OR coalesce(o.mx, 0) <> coalesce(k.lines, 0);
COPY (SELECT * FROM keep ORDER BY rel_path) TO (getvariable('staging') || '/manifest.parquet')
  (FORMAT parquet, COMPRESSION zstd, KV_METADATA {gen: @GEN@});
COPY (SELECT rel_path, src_size, src_mtime FROM keep ORDER BY rel_path) TO (getvariable('staging') || '/seen.tsv')
  (FORMAT csv, DELIMITER E'\t', HEADER false, QUOTE '', ESCAPE '');
