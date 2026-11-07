# ADR-0009: SQL files and the record contract

- **Status:** proposed
- **Date:** 2026-11-06
- **Deciders:** maintainer

## Context

- First outside contribution: three adapters.
- They needed only the normalized tables. Each still edited five or six shared files.
- Analysis parses raw `content` per runtime, and column meanings are unwritten.
- `input`, api_calls grain and unpaired tools each came back different ways. Whole-corpus JSON inference builds a giant struct.

## Decision

Three primitives: files, SQL files, one runner (`bin/duck`). Everything extensible is a SQL file. Files differ in what they read and what happens to their rows.

| Kind | Reads | Rows become |
|------|-------|-------------|
| adapter | the mirror | the four tables |
| check | the tables | failures (any row) |
| mine | the tables | a saved table |
| query | the tables | printed output |

- Fixed order: adapters, checks, swap, mines. No dependency graph, no general overlay, no option flags, no plugin hooks. Editing the SQL is the configuration.
- The repo holds mechanisms and examples. The data home holds anything tuned to one user.
- A runtime is one adapter, one fixture, one row in `runtimes.csv`. The data home holds `runtimes.csv`; the repo ships `runtimes.example.csv`. No row, no run.
- Adapters resolve from the data home first, then the repo. A contributor runs an adapter with no PR.
- Checks are `checks/*.sql`, replacing the single check file. Each must return no rows, and each row names the next action. Users add their own. A check reports orphaned ledger rows.
- `just mine` runs each `.sql` in the data home's `mining/` through `bin/duck`. No file, no mining. The repo's `mining/` holds one example detector per file and `patterns.example.csv`.
- Mines run after the swap. One failing mine does not stop the others or block publishing.
- A mine's version is the hash of its file. Mines read the four tables, never raw formats, and key on source ids so adjudications survive.
- Each CSV in the data home loads as a table named after it: attribution, pricing, patterns. The adjudication ledger is JSONL and gets the same treatment.
- Personal queries stay out of the repo. Users run theirs with `just sql -f <path>`.
- Four tables keep their names. `sql/record.sql` gives each column a written meaning.
- Ids come from the source. Unknown is NULL, never zero or invented. Never re-mean a column; add a new name.
- A column arrives with the query that reads it. Every JSON read lists explicit columns.
- Parsers report facts. Judgment stays in mining. Analysis never parses content or raw formats. `<rt>_*` nullable columns are the extension point.
- New columns: messages `origin`, `text`, `interrupted`; tool_calls `outcome` (ok, error, denied, cancelled, running), `arguments`, `result_text`, `mcp_server`, `mcp_tool`. `outcome` replaces `decision`.
- Splitting `corrections.sql` waits for messages `text`, `origin` and `interrupted`.

**Rejected:** an ext table, semver, renamed fact tables, a banned runtime literal in queries, a pluggable non-SQL parser (one real consumer), a dependency graph, a general overlay, option flags, plugin hooks.

## Consequences

**Positive**
- A new runtime touches three files, none of them shared. Unproven until one lands that way.

**Negative**
- Existing queries that read raw `content` must move to the new columns.

## References

- Amends ADR-0006. RFC-0001 carries the column text.
- Field signal: three outside adapter PRs (Copilot, Antigravity, Vibe).
