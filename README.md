![hero](hero.svg)

# varve

[![pipeline](https://gitlab.com/dunn.dev/varve/badges/main/pipeline.svg)](https://gitlab.com/dunn.dev/varve/-/pipelines)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
![built with GitLab](https://img.shields.io/badge/built_with-GitLab-FC6D26?logo=gitlab)

A varve is one annual sediment layer in a glacial lake. Scientists read varve
sequences to reconstruct past climate. This project is that instrument for an
agent estate: a local lake that accumulates readable layers of everything the
harness does, mined for signal.

varve normalizes on-disk agent-session records (Claude Code, pi, opencode) into
Parquet partitions and queries them with DuckDB. Files are canonical; the engine
is disposable. Zero resident processes, no listeners, zero egress.

It serves a goal ladder:

1. **Table stakes** -- efficiency wins from history (cost, cache, dispatch shape).
2. **Stretch** -- harness-tuning adequacy: do corrections land once and hold, or
   is the operator re-litigating the same decisions?
3. **Far stretch** -- a team-level post-training decision instrument: when has
   context engineering saturated?
4. **Supporting** -- historic record as simulation evidence and leak-free
   benchmark synthesis.

## Layout

| Path | What |
|------|------|
| `docs/prd.md` | Product requirements document -- the spine |
| `docs/adr/` | Architecture decision records (settled, dated, with evidence) |
| `docs/rfc/` | Requests for comment (designs still open to iteration) |
| `adapters/` | Per-runtime transcript normalizers (Claude Code, pi, opencode) |
| `queries/` | The versioned SQL query library -- the real analytics artifact |
| `tests/fixtures/` | Synthetic three-runtime corpus CI backfills against (`just test`) |
| `tests/snapshots/` | Expected rendered output `just test` diffs against |
| `justfile` | `just backfill` / `just ingest` / `just sql` / `just stats` / `just lint` / `just test` / `just disk` |

Toolchain: `mise install` provisions the pinned `duckdb` + `just` from
`mise.toml`; every recipe assumes both are on PATH.

Lake data never lives in this repo. It lands at `~/.local/share/varve/lake/`
(Parquet partitions) and `~/.local/share/varve/varve.duckdb` (rebuildable
views/marts).

## Status

PRD agreed 2026-07-06 (see `docs/prd.md`, pivot record inside). The lake
foundation, correction mining, and cost analytics are live on the author's
machines; adapters are validated to differing depths -- the pi adapter is the
least exercised and documents its own status (`adapters/pi.sql`).

Operator data — attribution rules, adjudications, worksheets — lives outside
this repo by design (ADR-0004): the instrument is public, the readings are not.
