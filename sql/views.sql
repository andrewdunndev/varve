-- varve engine layer. Rebuildable DuckDB views over the Parquet lake,
-- persisted in <data_home>/varve.duckdb. NOT the source of truth (ADR-0002):
-- drop the file and re-run backfill and it returns identically.
--
-- Written by the ingest/backfill writer (the sole writer). `just sql` opens this
-- database READ-ONLY and sets `lake` before querying, so the views resolve
-- without any write. Variable:
--   lake : <data_home>/lake
--
-- The views read hive-partitioned Parquet; runtime= and date= come from the
-- path. union_by_name tolerates the schema growing when pi/opencode land.

CREATE OR REPLACE VIEW sessions AS
SELECT * FROM read_parquet(getvariable('lake') || '/sessions/**/*.parquet',
  hive_partitioning = true, union_by_name = true);

CREATE OR REPLACE VIEW messages AS
SELECT * FROM read_parquet(getvariable('lake') || '/messages/**/*.parquet',
  hive_partitioning = true, union_by_name = true);

CREATE OR REPLACE VIEW api_calls AS
SELECT * FROM read_parquet(getvariable('lake') || '/api_calls/**/*.parquet',
  hive_partitioning = true, union_by_name = true);

CREATE OR REPLACE VIEW tool_calls AS
SELECT * FROM read_parquet(getvariable('lake') || '/tool_calls/**/*.parquet',
  hive_partitioning = true, union_by_name = true);

-- The correction views (correction_candidates, operator_messages, correction_events) are
-- created by `just mine` AFTER it writes those tables -- not here. CREATE VIEW binds its
-- read_parquet glob eagerly, and _views runs before the first mine (and correction_events
-- stays empty until the first adjudication round), so defining them here would fail on the
-- missing glob. `mine` runs in every pipeline pass, so the views are always (re)created
-- with the lake.
