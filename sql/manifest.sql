-- The manifest's columns, as the empty temp table m. A runtime with a
-- retained manifest has its rows inserted by the caller.
CREATE TEMP TABLE m (rel_path VARCHAR, bucket VARCHAR, bytes BIGINT, lines BIGINT, tail VARCHAR,
                     sha256 VARCHAR, src_size BIGINT, src_mtime VARCHAR, status VARCHAR);
