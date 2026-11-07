#!/usr/bin/env bash
# Startup views: TOML tables, JSONL ledgers and lake folders each become a view.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_views.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export VARVE_DATA="$tmp/data" VARVE_LOCK="$tmp/lock"
unset VARVE_LOCK_PID VARVE_LAKE VARVE_PUBLISHED
duck="$repo/bin/duck"
fail=0

want() { # NAME EXPECTED ACTUAL
  if [ "$2" != "$3" ]; then echo "FAIL: $1: want '$2', got '$3'" >&2; fail=1; else echo "  ok: $1" >&2; fi
}
q() { "$duck" views -noheader -list -c "$1"; }

mkdir -p "$VARVE_DATA/lake/things"
cat > "$VARVE_DATA/colors.toml" <<'T'
[[row]]
name = "red"
rank = 1

[[row]]
name = "blue"
rank = 2
T
: > "$VARVE_DATA/empty.toml"
printf '%s\n' '{"k":1}' 'not json' '{"k":2}' > "$VARVE_DATA/ledger.jsonl"
"$duck" views -c "COPY (SELECT 7 AS n) TO '$VARVE_DATA/lake/things/part.parquet' (FORMAT parquet);"

want "toml view" "red,blue" "$(q "SELECT string_agg(name, ',' ORDER BY rank) FROM colors")"
want "toml types" "2" "$(q "SELECT count(*) FROM colors WHERE typeof(rank) = 'BIGINT'")"
want "jsonl view reads good lines" "2" "$(q "SELECT count(*) FILTER (WHERE json_valid(j)) FROM ledger")"
want "lake folder view" "7" "$(q "SELECT n FROM things")"
rc=0; q "SELECT * FROM empty" >/dev/null 2>&1 || rc=$?
want "empty toml has no view" "2" "$rc"

printf '[[row\n' > "$VARVE_DATA/broken.toml"
rc=0; q "SELECT 1" >/dev/null 2>&1 || rc=$?
want "unparseable toml exits 2" "2" "$rc"

exit $fail
