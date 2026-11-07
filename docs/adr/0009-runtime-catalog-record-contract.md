# ADR-0009 -- Runtime catalog and record contract

- **Status:** proposed
- **Date:** 2026-11-06
- **Deciders:** operator + session

## Context

- First outside contribution: three adapters.
- They needed only the normalized tables. Each still edited five or six shared files.
- Analysis parses raw `content` per runtime, and column meanings are unwritten.
- `input`, api_calls grain and unpaired tools each came back different ways. Whole-corpus JSON inference builds a giant struct.

## Decision

- A runtime is one adapter file, one fixture, and rows in `runtimes.csv` (runtime, root, glob). A row present means enabled; several roots, several rows.
- Four tables keep their names. `sql/record.sql` gives each column a written meaning.
- Ids come from the source.
- Unknown is NULL, never zero or invented.
- Never re-mean a column. Add a new name.
- A column arrives with the query that reads it.
- Every JSON read lists explicit columns.
- Parsers report facts. Judgment stays in mining.
- Analysis never parses content or raw formats. Scoping by runtime is fine.
- Mining is opt-in per runtime.
- `<rt>_*` nullable columns are the extension point.
- New columns: messages `origin`, `text`, `interrupted`; tool_calls `outcome` (ok, error, denied, cancelled, running), `arguments`, `result_text`, `mcp_server`, `mcp_tool`. `outcome` replaces `decision`.
- `sql/check.sql`: each rule is a query. A returned row is a failure and names the next action. It runs inside build, so a failing lake cannot publish.

**Rejected:** an ext table, semver, renamed fact tables, a banned runtime literal in queries, a pluggable non-SQL parser (one real consumer).

## Consequences

**Positive**
- A new runtime touches three files. Unproven until one lands that way.

**Negative**
- Existing queries that read raw `content` must move to the new columns.

## References

- Amends ADR-0006. RFC-0001 carries the column text.
- Field signal: knightb8's Copilot, Antigravity and Vibe adapter PRs.
