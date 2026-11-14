-- One batch of a sync: the lines each changed source file has gained since it
-- was last retained, as a Parquet delta, plus the next manifest.
-- Variables: scan (tab file: rel, size, mtime), src (source root, trailing /),
--            out (staging folder), mdir. Placeholder @GEN@: the new generation.
-- m holds the current manifest (sql/manifest.sql). Writes into out/:
-- bucket=<b>/d-<gen>-<i>.parquet, manifest.parquet, seen.tsv. Prints
-- k<TAB>v counts.
-- The source bytes are handed to read_blob through maps keyed by path, never a
-- join with todo: a join buffers the blob side (4.2GB against 3.0GB peak).
-- Empty lists are typed because read_blob(NULL) fails.
CREATE TEMP TABLE scan AS
SELECT * FROM read_csv(getvariable('scan'), delim = E'\t', header = false, quote = '', escape = '',
                       columns = {'rel': 'VARCHAR', 'size': 'BIGINT', 'mtime': 'VARCHAR'});
CREATE TEMP TABLE todo AS
SELECT s.rel, getvariable('src') || s.rel AS path, s.size, s.mtime,
       strftime(make_timestamp((s.mtime::DOUBLE * 1000000)::BIGINT), '%G-W%V') AS week,
       m.bucket AS obucket, coalesce(m.bytes, 0) AS ob, coalesce(m.lines, 0) AS ol,
       m.tail AS otail, m.sha256 AS osha, m.rel_path IS NULL AS is_new,
       coalesce(m.bytes, 0) - coalesce(strlen(m.tail), 0) AS start
FROM scan s LEFT JOIN m ON m.rel_path = s.rel
WHERE m.rel_path IS NULL OR m.src_mtime <> s.mtime OR m.src_size <> s.size;
SET VARIABLE paths = coalesce((SELECT list(path ORDER BY path) FROM todo), []::VARCHAR[]);
SET VARIABLE st = (SELECT map(list(path), list(start)) FROM todo);
SET VARIABLE ob = (SELECT map(list(path), list(ob)) FROM todo);
SET VARIABLE osha = (SELECT map(list(path), list(coalesce(osha, ''))) FROM todo);
CREATE TEMP TABLE facts AS
WITH x AS (
  SELECT filename AS path, size AS n, sha256(content) AS sha,
         (getvariable('ob')[filename] = 0
          OR (size >= getvariable('ob')[filename]
              AND sha256(content[1 : getvariable('ob')[filename]]) = getvariable('osha')[filename])) AS prefix_ok,
         try(decode(content[getvariable('st')[filename] + 1 : size])) AS txt
  FROM read_blob(getvariable('paths')))
SELECT path, n, sha, prefix_ok, txt IS NOT NULL AS utf8,
       length(txt) - length(replace(txt, E'\n', '')) AS nl,
       CASE WHEN txt IS NULL OR txt = '' OR suffix(txt, E'\n') THEN NULL
            ELSE reverse(split_part(reverse(txt), E'\n', 1)) END AS tail
FROM x;
-- A new file's bucket is its ISO week, with a .k shard for every 512MB of
-- source bytes the week already holds.
CREATE TEMP TABLE held AS SELECT split_part(bucket, '.', 1) AS week, sum(bytes) AS b FROM m GROUP BY 1;
CREATE TEMP TABLE res AS
SELECT t.*, f.n, f.sha, f.prefix_ok, f.utf8, f.nl, f.tail,
       CASE WHEN NOT t.is_new THEN t.obucket
            ELSE CASE WHEN k = 0 THEN t.week ELSE t.week || '.' || k END END AS bucket
FROM (SELECT *, floor((coalesce(h.b, 0) + sum(size) OVER (PARTITION BY week ORDER BY rel) - size) / 536870912)::BIGINT AS k
      FROM todo LEFT JOIN held h USING (week)) t
JOIN facts f USING (path);
SET VARIABLE paths2 = coalesce((SELECT list(path ORDER BY path) FROM res WHERE prefix_ok AND utf8), []::VARCHAR[]);
SET VARIABLE st2 = (SELECT map(list(path), list(start)) FROM res WHERE prefix_ok AND utf8);
SET VARIABLE n2 = (SELECT map(list(path), list(n)) FROM res WHERE prefix_ok AND utf8);
SET VARIABLE sha2 = (SELECT map(list(path), list(sha)) FROM res WHERE prefix_ok AND utf8);
SET VARIABLE ol2 = (SELECT map(list(path), list(ol)) FROM res WHERE prefix_ok AND utf8);
SET VARIABLE bk2 = (SELECT map(list(path), list(bucket)) FROM res WHERE prefix_ok AND utf8);
COPY (
  SELECT rel_path, (ol + generate_subscripts(p, 1))::BIGINT AS line_no, unnest(p) AS line, bucket
  FROM (SELECT substr(filename, length(getvariable('src')) + 1) AS rel_path,
               getvariable('ol2')[filename] AS ol, getvariable('bk2')[filename] AS bucket,
               string_split(decode(content[getvariable('st2')[filename] + 1 : size]), E'\n')[1:-2] AS p
        FROM read_blob(getvariable('paths2'))
        WHERE size = getvariable('n2')[filename] AND sha256(content) = getvariable('sha2')[filename])
) TO (getvariable('out')) (FORMAT parquet, COMPRESSION zstd, COMPRESSION_LEVEL 9, ROW_GROUP_SIZE 20000,
                           ROW_GROUP_SIZE_BYTES '64MB', PARTITION_BY (bucket), FILENAME_PATTERN 'd-@GEN@-{i}',
                           OVERWRITE_OR_IGNORE);
-- A zero-row file keeps the readback below valid when no source gained a line.
COPY (SELECT ''::VARCHAR AS rel_path, 0::BIGINT AS line_no, ''::VARCHAR AS line WHERE false)
  TO (getvariable('out') || '/none.parquet') (FORMAT parquet);
CREATE TEMP TABLE got AS
SELECT rel_path, count(*) AS c, sum(strlen(line) + 1) AS b
FROM read_parquet(getvariable('out') || '/**/*.parquet', hive_partitioning = false)
GROUP BY 1;
-- A file is retained only when the delta holds exactly its new lines and bytes.
CREATE TEMP TABLE good AS
SELECT r.* FROM res r LEFT JOIN got g ON g.rel_path = r.rel
WHERE r.prefix_ok AND r.utf8 AND coalesce(g.c, 0) = r.nl
  AND coalesce(g.b, 0) = r.n - r.start - coalesce(strlen(r.tail), 0);
CREATE TEMP TABLE mnew AS
SELECT rel_path, bucket, bytes, lines, tail, sha256, src_size, src_mtime, status FROM m
WHERE rel_path NOT IN (SELECT rel FROM good) AND rel_path NOT IN (SELECT rel FROM res WHERE NOT prefix_ok AND NOT is_new)
UNION ALL
SELECT rel, bucket, n, ol + nl, tail, sha, size, mtime, 'ok' FROM good
UNION ALL
SELECT m.rel_path, m.bucket, m.bytes, m.lines, m.tail, m.sha256, r.size, r.mtime, 'diverged'
FROM res r JOIN m ON m.rel_path = r.rel WHERE NOT r.prefix_ok AND NOT r.is_new;
COPY (SELECT * FROM mnew ORDER BY rel_path) TO (getvariable('out') || '/manifest.parquet')
  (FORMAT parquet, COMPRESSION zstd, KV_METADATA {gen: @GEN@});
COPY (SELECT rel_path, src_size, src_mtime FROM mnew ORDER BY rel_path) TO (getvariable('out') || '/seen.tsv')
  (FORMAT csv, DELIMITER E'\t', HEADER false, QUOTE '', ESCAPE '');
SELECT 'new' AS k, count(*) AS v FROM good WHERE is_new
UNION ALL SELECT 'grown', count(*) FROM good WHERE NOT is_new
UNION ALL SELECT 'diverged', count(*) FROM res WHERE NOT prefix_ok AND NOT is_new
UNION ALL SELECT 'unretained', count(*) FROM res WHERE prefix_ok AND NOT utf8
UNION ALL SELECT 'unstable', count(*) FROM res WHERE prefix_ok AND utf8 AND rel NOT IN (SELECT rel FROM good);
