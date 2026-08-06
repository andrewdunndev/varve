# ADR-0002 -- Files are the lake; engines are disposable (Parquet + DuckDB in v1)

- **Status:** accepted
- **Date:** 2026-07-06
- **Deciders:** operator + session

## Context

**The preselection.** The campaign scaffold said the stack was "likely clickhouse
based." That preselection rode unchallenged through the first grill session and into
the first draft of the PRD: ClickStack (HyperDX) all-in-one, run under Apple's
`container` runtime, with an OpenTelemetry Protocol (OTLP) live plane, a LaunchAgent
for auto-start, three named volumes, and time-to-live (TTL) surgery on the product's
default tables.

**The challenge (operator, 2026-07-06).** Why a server-class column store for a
single-user laptop?

**The empirical basis.** The operator's *entire* transcript history -- all of it,
because the 30-day cleanup already deleted the rest -- is **774 MB across 782 JSONL
files, ~56K API calls.** Even heavy multi-year use projects to single-digit GB of raw
text and low-millions of structured rows: **3-4 orders of magnitude below ClickHouse's
design point.** A live demo installed DuckDB (a fresh single binary) and aggregated the
full history in place, in seconds. Nearly all of the old W1 machinery -- container
runtime, LaunchAgent workarounds, colima fallback, volume management, TTL surgery, the
Mongo dependency, disk-watch scripts -- existed only because the engine was
server-shaped. Remove the server and the machinery evaporates.

## Decision

- The **canonical artifact is normalized Parquet** (zstd) plus the schema plus the
  versioned SQL query library. Adapters write Parquet; any engine reads it.
- The **v1 engine is DuckDB** -- a mise-pinned single binary. No server, no container
  runtime, no listener, no resident process.
- **ClickHouse / ClickStack is deferred, not rejected.** The deferral condition is a
  stage that genuinely needs always-on ingest, multi-writer, or multi-user access (the
  team stage, or the x86 Linux box). ClickHouse reads Parquet natively, so the lake
  ports with no rewrite -- only the engine swaps (RFC-0004 §b).
- **Apple `container` is dropped from v1 scope** along with the server it existed to
  host. "Prove the concept before we attempt to think of running it at scale."

**Alternatives considered.**

- *ClickStack (HyperDX) all-in-one* -- deferred. Server-shaped and overkill at this
  scale: Mongo + volumes + TTL defaults + container overhead for data that fits in
  memory.
- *Bare single-binary ClickHouse (no HyperDX)* -- still a daemon and a listener.
  DuckDB is lighter for embedded single-user analytics and reads the raw JSONL in
  place.
- *SigNoz* -- ClickHouse-native but heavier; AGPL core; ZooKeeper dependency.
- *Grafana + ClickHouse (do-it-yourself)* -- maximum flexibility, but you own every
  migration and dashboard.
- *OpenObserve* -- light, but not ClickHouse and not SQL-first.
- *Uptrace* -- needs Postgres; tracing-leaning.
- *Apple `container` runtime* -- dropped with the server. Deferred-stage references
  (persistence gaps, virtiofs bind-mount bug) are retained in the PRD appendix.

## Consequences

**Positive**
- Zero ops: no daemon to run, patch, or auto-start; nothing bound to any interface
  (confidentiality improves -- ADR-0004).
- The v1 Claude Code adapter can be near-pure SQL: DuckDB `read_json_auto` over the
  raw JSONL, `CREATE TABLE AS SELECT` into Parquet.
- The whole instrument is files plus a pinned binary -- reproducible via `mise` + `just`.

**Negative**
- DuckDB is **single-writer.** Ingest and interactive analysis must not both write
  (mitigation: ingest is the sole writer; analysis attaches read-only -- see PRD Risks).
- Engine re-entry cost at the team stage. Mitigated by design: Parquet and the SQL
  library port natively; the engine is the disposable part (RFC-0004 §b).

**Neutral**
- The presentation layer is left undecided (notebook / report / none); not required
  for v1.
- The deferred-stage research (ClickStack, Apple `container`) is parked, not lost (PRD
  appendix; RFC-0004 §b).

## References

- PRD sections: Pivot record (2026-07-06); D2 / D3 / D8; W1 -- Lake foundation;
  Appendix (deferred-stage reference).
- Related: ADR-0001 (why a lake at all), ADR-0004 (confidentiality gain from no
  listener), RFC-0004 §b (engine re-entry).
- External: DuckDB <https://duckdb.org/> (MIT); Apache Parquet
  <https://parquet.apache.org/>; ClickStack docs
  <https://clickhouse.com/docs/use-cases/observability/clickstack>; apple/container
  issues [#333](https://github.com/apple/container/issues/333),
  [#286](https://github.com/apple/container/issues/286),
  [#158](https://github.com/apple/container/issues/158),
  [#1321](https://github.com/apple/container/issues/1321).
