-- varve incremental delta detection (W1; W2 keys on the unified _files map so
-- all runtimes share one manifest). Runs after prelude + adapters + stage.sql,
-- before the COPY-to-lake statements. Computes _affected (date partitions to
-- rewrite) and _inventory (current per-file high-water mark) to persist as the
-- new manifest.
--
-- Variables (set by the justfile):
--   mode      : 'backfill' (rewrite every date) | 'ingest' (rewrite changed only)
--   inventory : path to the current file-stat CSV (path,size,mtime) from `find`
--   manifest  : path to the previous manifest parquet (justfile guarantees it
--               exists, empty on first run)
--
-- Idempotence: a file's high-water mark is (size, mtime). A file is "changed"
-- iff new, or size/mtime differ from the manifest. Claude Code appends to the
-- live session's JSONL, growing size+mtime -> that session's date is rebuilt
-- from the CURRENT full file content, so appended rows are counted exactly once
-- (deterministic re-derivation). No change -> no affected dates -> no writes ->
-- identical row counts on re-run.

CREATE OR REPLACE TABLE _inventory AS
SELECT path, size::bigint AS size, mtime::bigint AS mtime
FROM read_csv(getvariable('inventory'), header = true, auto_detect = true);

CREATE OR REPLACE TABLE _prev AS
SELECT * FROM read_parquet(getvariable('manifest'));

CREATE OR REPLACE TABLE _changed AS
SELECT c.path
FROM _inventory c
LEFT JOIN _prev p ON c.path = p.path
WHERE p.path IS NULL OR c.size <> p.size OR c.mtime <> p.mtime;

-- Dates to (re)write. Backfill = all; ingest = dates of sessions whose files
-- changed (across all runtimes, via the unified _files map). A date partition is
-- rebuilt in full from ALL its co-resident sessions (staging holds every derived
-- session), so unchanged sessions sharing the date are preserved. A runtime whose
-- adapter was skipped this cycle contributes no rows to stg_*, so OVERWRITE_OR_
-- IGNORE leaves its existing partitions in place untouched.
CREATE OR REPLACE TABLE _affected AS
SELECT DISTINCT date FROM stg_sessions
WHERE getvariable('mode') = 'backfill'
   OR date IN (SELECT f.date FROM _files f JOIN _changed ch ON f.path = ch.path);
