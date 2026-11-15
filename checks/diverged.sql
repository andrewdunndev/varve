-- A retained file whose source was rewritten or cut short keeps its old bytes;
-- the bytes the source gained since are not in the lake.
CREATE VIEW IF NOT EXISTS manifests AS SELECT NULL::VARCHAR AS filename, NULL::VARCHAR AS status WHERE false;
SELECT count(*) || ' retained file(s) in ' || regexp_replace(filename, '/manifest\.parquet$', '') || ' diverged from their source; the retained bytes were kept and the source''s newer content is not in the lake' AS action
FROM manifests WHERE status = 'diverged'
GROUP BY filename ORDER BY filename;
