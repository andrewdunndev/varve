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


# A replace pair that changes mid-copy ships as neither file. The shim lets the
# real cp run, then grows the watched source so its stat differs afterwards.
shim="$tmp/shim"; mkdir -p "$shim"
cat > "$shim/cp" <<S
#!/bin/sh
$(command -v cp) "\$@" || exit \$?
if [ "\$2" = "\${SHIM_TRIG:-\$SHIM_GROW}" ] && [ "\$(cat "\$SHIM_TIMES")" -gt 0 ]; then
  echo \$((\$(cat "\$SHIM_TIMES") - 1)) > "\$SHIM_TIMES"
  printf x >> "\$SHIM_GROW"
fi
if [ "\$2" = "\${SHIM_SHRINK:-}" ]; then printf b > "\$3"; fi
S
chmod +x "$shim/cp"
export SHIM_GROW="$src/store.db-wal" SHIM_TIMES="$tmp/times"

printf 'db2\n' > "$src/store.db"; printf 'wal-two-longer\n' > "$src/store.db-wal"
echo 99 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>"$tmp/err"
want "unstable pair keeps old db" "db1" "$(cat "$m/store.db")"
want "unstable pair keeps old wal" "w" "$(cat "$m/store.db-wal")"
want "unstable pair is logged" "yes" "$(grep -q 'kept 2 unstable' "$tmp/err" && echo yes || echo no)"
want "unstable pair leaves no temp" "0" "$(find "$m" -name '*.tmp.*' | wc -l | tr -d ' ')"

echo 1 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "pair ships once stable (db)" "db2" "$(cat "$m/store.db")"
want "pair ships once stable (wal)" "yes" "$(cmp -s "$src/store.db-wal" "$m/store.db-wal" && echo yes || echo no)"

# The journal changing after the database was copied (a checkpoint between the
# two copies) ships as neither file.
printf 'db-four\n' > "$src/store.db"
export SHIM_TRIG="$src/store.db"
echo 99 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>"$tmp/err"
want "checkpoint between copies keeps old db" "db2" "$(cat "$m/store.db")"
want "checkpoint between copies is logged" "yes" "$(grep -q 'kept 2 unstable' "$tmp/err" && echo yes || echo no)"
echo 1 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "set ships once the journal settles" "db-four" "$(cat "$m/store.db")"
unset SHIM_GROW SHIM_TIMES SHIM_TRIG

# A journal the source no longer has leaves the mirror with the new database.
rm -f "$src/store.db-wal"; printf 'db5\n' > "$src/store.db"
"$sync" 2>/dev/null
want "vanished journal: new db shipped" "db5" "$(cat "$m/store.db")"
want "vanished journal: mirror journal removed" "no" "$([ -e "$m/store.db-wal" ] && echo yes || echo no)"

# A copy that comes out shorter than the mirror's file is dropped.
printf 'bbbbbbbbbbbbbbbb\n' > "$src/proj/one.jsonl"
SHIM_SHRINK="$src/proj/one.jsonl" PATH="$shim:$PATH" "$sync" 2>"$tmp/err"
want "shortened copy keeps the mirror file" "aaaaaaaa" "$(cat "$m/proj/one.jsonl")"
want "shortened copy is counted skipped" "yes" "$(grep -q 'skipped 1 shorter' "$tmp/err" && echo yes || echo no)"
want "shortened copy leaves no temp" "0" "$(find "$m" -name '*.tmp.*' | wc -l | tr -d ' ')"

# A temp stranded by a killed run is swept at the next sync.
printf junk > "$m/proj/one.jsonl.tmp.4242"
"$sync" 2>/dev/null
want "stranded temp swept" "0" "$(find "$m" -name '*.tmp.*' | wc -l | tr -d ' ')"

# Nothing outside the source root is copied: symlinked files and directories
# are not followed, a replace entry through a symlink is skipped, and an entry
# with '..' or a leading '/' fails the run.
mkdir -p "$tmp/outside" "$tmp/src2/real"
printf 'outside\n' > "$tmp/outside/secret.jsonl"; printf 'outside-db\n' > "$tmp/outside/secret.db"
ln -s "$tmp/outside/secret.jsonl" "$tmp/src2/real/link.jsonl"
ln -s "$tmp/outside" "$tmp/src2/linkdir"
ln -s "$tmp/outside/secret.db" "$tmp/src2/store.db"
printf 'inside\n' > "$tmp/src2/real/in.jsonl"
cat > "$VARVE_DATA/runtimes.toml" <<T
[[row]]
name = "beta"
adapter = "beta.sql"
source = "$tmp/src2"
include = ["*.jsonl", "*.db"]
replace = ["store.db", "linkdir/secret.db"]
T
"$sync" 2>/dev/null
b="$VARVE_DATA/mirror/beta"
want "real file copied" "inside" "$(cat "$b/real/in.jsonl")"
want "symlinked file not copied" "no" "$([ -e "$b/real/link.jsonl" ] && echo yes || echo no)"
want "symlinked dir not followed" "no" "$([ -e "$b/linkdir" ] && echo yes || echo no)"
want "symlinked replace entry not copied" "no" "$([ -e "$b/store.db" ] && echo yes || echo no)"

for bad in 'real|../outside/secret.db' 'real|/etc/hostname' 'real|real/../../outside/secret.db' '../outside/*.jsonl|store.db'; do
  inc="${bad%%|*}"; rep="${bad#*|}"
  case "$inc" in real) inc='*.jsonl' ;; esac
  cat > "$VARVE_DATA/runtimes.toml" <<T
[[row]]
name = "gamma"
adapter = "gamma.sql"
source = "$tmp/src2"
include = ["$inc"]
replace = ["$rep"]
T
  rc=0; "$sync" 2>"$tmp/err" || rc=$?
  want "escape refused: $inc $rep" "2" "$rc"
  want "escape copied nothing: $inc $rep" "0" "$(find "$VARVE_DATA/mirror/gamma" -type f 2>/dev/null | wc -l | tr -d ' ')"
done

exit $fail
