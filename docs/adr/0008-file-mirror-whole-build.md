# ADR-0008 -- File mirror and whole build

- **Status:** proposed
- **Date:** 2026-11-06
- **Deciders:** operator + session

## Context

- Ingest parses every source each run. The manifest only skips the final write.
- Date rewrites drop rows whose source file is gone, against ADR-0003. Read in code, not yet run.
- Source formats have no stable line unit. Files are rewritten, compressed, rewound.
- One parser failure stops the nightly job for every runtime.

## Decision

- The lake is f(mirror, operator data, repo).
- `sync` copies allowed files, parses nothing, and is the only scheduled step.
- `build` runs one process per runtime into `lake.new`, then mines, checks, swaps.
- A runtime that fails keeps its last good partitions.
- Nothing shrinks except by `just forget`.
- The mirror never replaces a file with a shorter one.
- A build that would lose a session the published lake holds fails `check`. The old lake stays.
- `ingest`, `backfill`, the manifest, `sql/affected.sql` and `sql/stage.sql` go.

**Rejected**
- Line-grain capture into Parquet: no stable unit.
- One Parquet part per source file: about 90,000 tiny files.
- Scoped incremental rewrites: nothing to save while parse is whole.

## Consequences

**Positive**
- A failed parser costs one runtime, not the night.

**Negative**
- The mirror adds a tier and widens the confidentiality surface. It is an allow-list.
- A rewound file that later outgrows its old length overwrites the rewound tail. Accepted.
- Rows deleted inside a SQLite source are not protected. `check` reports the loss.

**Neutral**
- Whole-build time is unmeasured. If a capped build is too slow, build goes incremental by (runtime, month).
- `messages` is 99% of the lake. `content` retires once the mirror holds the verbatim copy. No compression change until measured.

## References

- Amends ADR-0002 (canonical is mirror plus repo; Parquet is derived), ADR-0003 (keep-everything binds the mirror), ADR-0004 I2 (Parquet lake wording).
