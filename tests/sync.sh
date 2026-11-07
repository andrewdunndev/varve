#!/usr/bin/env bash
# bin/sync: grow-only copy, allow-list, forgotten sessions, replace set.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_sync.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export VARVE_DATA="$tmp/data" VARVE_LOCK="$tmp/lock"
unset VARVE_MIRROR VARVE_SYNC_NICED
sync="$repo/bin/sync"
src="$tmp/src"
fail=0

want() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1: want '$2', got '$3'" >&2; fail=1; else echo "  ok: $1" >&2; fi
}
mkdir -p "$VARVE_DATA" "$src/proj"
cat > "$VARVE_DATA/runtimes.toml" <<T
[[row]]
name = "alpha"
adapter = "alpha.sql"
source = "$src"
include = ["*.jsonl", "store.db", "store.db-wal"]
replace = ["store.db", "store.db-wal"]
T
m="$VARVE_DATA/mirror/alpha"

printf 'aaaa\n' > "$src/proj/one.jsonl"
printf 'secret\n' > "$src/proj/.credentials.json"
printf 'db1\n' > "$src/store.db"; printf 'wal-long\n' > "$src/store.db-wal"
"$sync" 2>/dev/null
want "copied" "aaaa" "$(cat "$m/proj/one.jsonl")"
want "sibling not copied" "no" "$([ -e "$m/proj/.credentials.json" ] && echo yes || echo no)"
want "replace pair copied" "db1 wal-long" "$(cat "$m/store.db") $(cat "$m/store.db-wal")"

printf 'aa\n' > "$src/proj/one.jsonl"
"$sync" 2>/dev/null
want "shorter source kept" "aaaa" "$(cat "$m/proj/one.jsonl")"

printf 'aaaaaaaa\n' > "$src/proj/one.jsonl"
"$sync" 2>/dev/null
want "longer source copied" "aaaaaaaa" "$(cat "$m/proj/one.jsonl")"

printf 'w\n' > "$src/store.db-wal"
"$sync" 2>/dev/null
want "wal shrink replaced" "w" "$(cat "$m/store.db-wal")"

printf 'xx\n' > "$src/proj/gone-session-9.jsonl"
cat > "$VARVE_DATA/forgotten.toml" <<'T'
[[row]]
session_id = "session-9"
runtime = "alpha"
at = "2026-01-01"
T
"$sync" 2>/dev/null
want "forgotten not copied" "no" "$([ -e "$m/proj/gone-session-9.jsonl" ] && echo yes || echo no)"

exit $fail
