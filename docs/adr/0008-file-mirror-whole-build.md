# ADR-0008: File mirror and whole build

- **Status:** accepted
- **Date:** 2026-11-06
- **Deciders:** maintainer

## Context

- Ingest parses every source each run. The manifest only skips the final write.
- Date rewrites drop rows whose source file is gone, against ADR-0003. Read in code, not yet run.
- Source formats have no stable line unit. Files are rewritten, compressed, rewound.
- One parser failure stops the nightly job for every runtime.

## Decision

- The lake is f(mirror, operator data, repo).
- `sync` copies allowed files, parses nothing, and is the only scheduled step.
- `build` runs one process per runtime into `lake.new`, then checks, then swaps. Mines run after the swap.
- A runtime that fails keeps its last good partitions. A runtime that built owns its partitions.
- Nothing shrinks except by `just forget` and the replace set (see Consequences).
- The mirror never replaces a file with a shorter one, except in the replace set.
- A build that would lose a session, or net rows per runtime and table, that the published lake holds fails a check. The old lake stays, and after a swap it stays as `lake.old` until the next build starts. If a flagged count is right, move the lake aside, keep it, and rebuild.
- `ingest`, `backfill`, the manifest, `sql/affected.sql` and `sql/stage.sql` go.
- `varve.duckdb` goes. Startup generates one view per lake folder, so a mine's table appears on its own. `sql/views.sql` and the view step in `mine` go, and with them the single-writer risk.
- `just test` is build over fixtures. The fixtures are a mirror and assertions are checks, so tests and real runs share one path.
- `build` reads the mirrored opencode database. The temporary snapshot in `_pipeline` goes.

**Rejected**
- Line-grain capture into Parquet: no stable unit.
- One Parquet part per source file: tens of thousands of tiny files.
- Scoped incremental rewrites: nothing to save while parse is whole.

## Consequences

**Positive**
- A failed parser costs one runtime, not the night.

**Negative**
- The mirror adds a tier and widens the confidentiality surface. It is an allow-list.
- A rewound file that later outgrows its old length overwrites the rewound tail. Accepted.
- Rows deleted inside a SQLite source are not protected. `check` reports the loss.
- Parquet footers are read on every query once no database holds the views. The cost is unmeasured.
- CI reads a real SQLite WAL through the mirror: rows held only in a live store's `-wal` reach the mirror and read back through `sqlite_scan`, a clean close drops the `-wal` from the mirror, and a read leaves the mirror's database and non-empty `-wal` byte-identical, adding only an empty `-wal` and a `-shm`. A live opencode install is still untested.
- SQLite files are exempt from never-shorter: a stale database and journal pair corrupts, so they are replaced together or not at all, and a member the source has dropped leaves the mirror with the set. A source file reached through a symlink or `..`, or by an absolute path, is never copied.

**Neutral**
- Whole-build time is unmeasured. If a capped build is too slow, build goes incremental by (runtime, month).
- `messages` dominates lake size. `content` is retired; the mirror holds the verbatim copy. No compression change until measured.

## References

- Amends ADR-0002 (canonical is mirror plus repo; Parquet is derived), ADR-0003 (keep-everything binds the mirror), ADR-0004 I2 (Parquet lake wording).
