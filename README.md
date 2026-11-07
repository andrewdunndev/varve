![hero](hero.svg)

# varve

[![pipeline](https://gitlab.com/dunn.dev/varve/badges/main/pipeline.svg)](https://gitlab.com/dunn.dev/varve/-/pipelines)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![built with GitLab](https://img.shields.io/badge/built_with-GitLab-FC6D26?logo=gitlab)

A varve is one annual sediment layer in a glacial lake. Scientists read varve
sequences to reconstruct past climate. This project is that instrument for
coding-agent sessions: a local lake that accumulates readable layers of
everything your agents did, mined for signal.

varve normalizes on-disk agent-session records (Claude Code, pi, opencode) into
Parquet partitions and queries them with DuckDB. Files are canonical; the engine
is disposable. Zero resident processes, no listeners, zero egress.

It serves a goal ladder:

1. **Table stakes:** efficiency wins from history (cost, cache, dispatch shape).
2. **Stretch:** do corrections land once and hold, or do you keep re-litigating
   the same decisions?
3. **Far stretch:** a team-level post-training decision instrument: when has
   context engineering saturated?
4. **Supporting:** the historic record as simulation evidence and leak-free
   benchmark synthesis.

Only the first rung needs the core. The rest are layers over the four tables.

## Architecture

Target design (ADR-0008 to ADR-0010, proposed). `just ingest` runs until it is built.

Three primitives: files, SQL files, one runner (`bin/duck`). Everything extensible is a SQL file, run in a fixed order: adapters, checks, swap, mines.

| Kind | Reads | Rows become |
|------|-------|-------------|
| adapter | the mirror | the four tables |
| check | the tables | failures |
| mine | the tables | a saved table |
| query | the tables | printed output |

![Runtime stores are copied into a mirror, built into a new lake, checked, and swapped in. Mines run after the swap.](docs/img/tiers.svg)

The mirror and your data home cannot be rebuilt.

![A new runtime adds an adapter, a fixture and a runtimes row.](docs/img/runtime.svg)

A new runtime touches three files.

![Every SQL file runs inside the bin/duck boundary.](docs/img/envelope.svg)

One wrapper bounds every DuckDB process.

## Layout

| Path | What |
|------|------|
| `adapters/` | Per-runtime normalizers (Claude Code, pi, opencode) and the pricing and attribution seeds |
| `sql/` | Shared prelude, staging, delta detection and lake views |
| `queries/` | The versioned SQL query library |
| `mining/` | Correction mining, review rendering, year-in-review stats and their queries |
| `docs/` | PRD, ADRs (`adr/`), RFCs (`rfc/`), query index |
| `tests/` | Synthetic three-runtime fixtures and expected output for `just test` |
| `justfile` | `backfill`, `ingest`, `mine`, `review`, `stats`, `sql`, `lint`, `test`, `disk` |

`mise install` provisions the pinned `duckdb` and `just` from `mise.toml`.

Lake data never lives in this repo. It lands in `~/.local/share/varve/`. Your
data (attribution rules, adjudications, worksheets) lives there too, by design
(ADR-0004): the instrument is public, the readings are not.

## Status

The lake, correction mining and cost analytics are in use. The pi adapter is the
least exercised and documents its own status (`adapters/pi.sql`).

## Contributing

GitLab is canonical. GitHub is a push mirror.
Adapters for new runtimes are welcome.
A pull request on the mirror is ported to GitLab with authorship kept.
Adapters should follow ADR-0009.
