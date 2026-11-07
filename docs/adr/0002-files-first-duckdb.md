# ADR-0002: Files are the lake, engines are disposable (Parquet + DuckDB in v1)

- **Status:** accepted
- **Amended by:** ADR-0008 (canonical is the mirror plus the repo; Parquet is derived)
- **Date:** 2026-07-06
- **Deciders:** maintainer

## Context

The first PRD draft preselected a server-class column store: ClickStack (HyperDX) under
Apple's `container` runtime, with an OTLP live plane, a LaunchAgent, volumes and TTL surgery.

A single user's transcript history is small. Even heavy multi-year use projects to
single-digit GB of raw text and low millions of rows, three to four orders of magnitude
below ClickHouse's design point. A fresh DuckDB binary aggregates such a history in place,
in seconds. Nearly all of the planned machinery (container runtime, LaunchAgent workarounds,
colima fallback, volumes, TTL surgery, Mongo, disk-watch scripts) existed only because the
engine was server-shaped.

## Decision

- The canonical artifact is normalized Parquet (zstd) plus the schema plus the
  versioned SQL query library. Adapters write Parquet; any engine reads it.
- The v1 engine is DuckDB, a mise-pinned single binary. No server, no container
  runtime, no listener, no resident process.
- ClickHouse / ClickStack is deferred, not rejected. The deferral ends at a stage that
  needs always-on ingest, multi-writer or multi-user access (a team stage, or a
  server). ClickHouse reads Parquet natively; only the engine swaps.
- Apple `container` is dropped from v1 scope with the server it existed to host.

**Alternatives considered.**

- ClickStack (HyperDX) all-in-one: deferred. Server-shaped (Mongo, volumes, TTL defaults,
  container overhead) for data that fits in memory.
- Bare single-binary ClickHouse: still a daemon and a listener. DuckDB is lighter and
  reads raw JSONL in place.
- SigNoz: ClickHouse-native but heavier; AGPL core; ZooKeeper dependency.
- Grafana + ClickHouse (do-it-yourself): most flexible; you own every migration and dashboard.
- OpenObserve: light, but not ClickHouse and not SQL-first.
- Uptrace: needs Postgres; tracing-leaning.
- Apple `container` runtime: dropped with the server (open issues linked below).

## Consequences

**Positive**
- Zero ops: no daemon to run, patch or auto-start; nothing bound (ADR-0004).
- The Claude Code adapter is near-pure SQL: `read_json` with explicit columns over raw JSONL into Parquet.
- Files plus a pinned binary, reproducible with `mise` and `just`.

**Negative**
- DuckDB is single-writer: ingest is the sole writer; analysis attaches read-only.
- Engine re-entry cost at a team stage; Parquet and the SQL library port natively.

**Neutral**
- The presentation layer (notebook, report, none) is undecided; not required for v1.

## References

- PRD sections: Decisions (D2, D3, D8); Architecture; Risks.
- Related: ADR-0001 (why a lake at all), ADR-0004 (no server means no listener).
- External: [DuckDB](https://duckdb.org/) (MIT); [Apache Parquet](https://parquet.apache.org/);
  [ClickStack](https://clickhouse.com/docs/use-cases/observability/clickstack); apple/container
  issues [#333](https://github.com/apple/container/issues/333), [#286](https://github.com/apple/container/issues/286),
  [#158](https://github.com/apple/container/issues/158), [#1321](https://github.com/apple/container/issues/1321).
