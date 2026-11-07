# ADR-0009: SQL files and the record contract

- **Status:** accepted
- **Date:** 2026-11-06
- **Deciders:** maintainer

## Context

- First outside contribution: three adapters.
- Each needed only the normalized tables, and each edited five or six shared files.
- Analysis parses raw `content` per runtime, and column meanings are unwritten.
- `input`, api_calls grain and unpaired tools each came back different ways. Whole-corpus JSON inference builds a giant struct.

## Decision

Three primitives: files, SQL files, one runner (`bin/duck`). Everything extensible is a SQL file.

| Kind | Reads | Rows become |
|------|-------|-------------|
| adapter | the mirror | the four tables |
| check | the tables | failures (any row) |
| mine | the tables | a saved table |
| query | the tables | printed output |

- Fixed order: adapters, checks, swap, mines. Editing the SQL is the configuration.
- The repo holds mechanisms and examples. The data home holds anything tuned to one user.
- A runtime is one adapter, one fixture, one row in `runtimes.toml`. The data home holds `runtimes.toml`; the repo ships `runtimes.example.toml`. No row, no run.
- Adapters resolve from the data home first, then the repo. A contributor runs an adapter with no PR.
- Checks are `checks/*.sql`, replacing the single check file. Each must return no rows, and each row names the next action. Users add their own. A check reports orphaned ledger rows.
- `just mine` runs each `.sql` in the data home's `mining/` through `bin/duck`. No file, no mining. The repo's `mining/` holds one example detector per file and `patterns.example.toml`.
- Mines run after the swap. One failing mine does not stop the others or block publishing.
- A mine's version is the hash of its file. Mines read the four tables, never raw formats, and key on source ids so adjudications survive.
- Config is TOML. Each TOML file in the data home loads as a table named after it: attribution, pricing, patterns. A pinned `yq` converts it, which is unproven here. The adjudication ledger is JSONL and gets the same treatment.
- Personal queries stay out of the repo. Users run theirs with `just sql -f <path>`.
- Four tables keep their names. `sql/record.sql` gives each column a written meaning.
- Ids come from the source. Unknown is NULL, never zero or invented. Never re-mean a column; add a new name. The exception is the summed measures: a call with no recorded usage reads 0 tokens and a model with no price reads 0 `cost_usd`, because every consumer sums them; `unpriced_model` carries the signal.
- A column arrives with the query that reads it. Every JSON read of source data lists explicit columns. The exception is a config table: its columns are whatever the user's TOML rows name, so `bin/duck` reads them with inferred types over the whole file.
- Parsers report facts. Judgment stays in mining. Analysis never parses content or raw formats. `<rt>_*` nullable columns are the extension point.
- New columns: messages `origin`, `text`, `interrupted`; tool_calls `outcome` (ok, error, denied, cancelled, running), `arguments`, `result_text`, `mcp_server`, `mcp_tool`. `outcome` replaces `decision`.

**Rejected:** an ext table, semver, renamed fact tables, a banned runtime literal in queries, a pluggable non-SQL parser (one real consumer), a dependency graph, a general overlay, option flags, plugin hooks.

## Consequences

**Positive**
- A new runtime touches three files, none of them shared. Unproven until one lands that way.

**Negative**
- Existing queries that read raw `content` must move to the new columns.

## References

- Amends ADR-0006. RFC-0001 carries the column text.
- Field signal: three outside adapter PRs (Copilot, Antigravity, Vibe).
