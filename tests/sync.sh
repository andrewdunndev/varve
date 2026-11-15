#!/usr/bin/env bash
# bin/sync: allow-list, forgotten sessions, the replace set that moves a database
# and its journal together, and nothing copied from outside the source root.
# Retention of line files is tests/retain.sh.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_sync.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export VARVE_DATA="$tmp/data" VARVE_LOCK="$tmp/lock"
unset VARVE_MIRROR VARVE_SYNC_NICED VARVE_LOCK_PID
sync="$repo/bin/sync"
src="$tmp/src"
fail=0
zd() { zstd -dc "$1"; }
mtn() { if stat --version >/dev/null 2>&1; then stat -c %.9Y "$1"; else stat -f %Fm "$1"; fi; }
# rels MIRROR: the retained source files, comma separated.
rels() { "$repo/bin/duck" rels -noheader -list -c "SELECT coalesce(string_agg(rel_path, ',' ORDER BY rel_path), '') FROM read_parquet('$1/manifest.parquet');"; }

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
want "a line file is retained as lines" "proj/one.jsonl" "$(rels "$m")"
want "no plain copy and no frame of a line file" "no" "$([ -e "$m/proj/one.jsonl" ] || [ -e "$m/proj/one.jsonl.zst" ] && echo yes || echo no)"
want "sibling not copied" "no" "$([ -e "$m/proj/.credentials.json" ] && echo yes || echo no)"
want "replace pair copied" "db1 wal-long" "$(zd "$m/store.db.zst") $(zd "$m/store.db-wal.zst")"
want "the replace set stays out of the lines" "proj/one.jsonl" "$(rels "$m")"

printf 'w\n' > "$src/store.db-wal"
"$sync" 2>/dev/null
want "wal shrink replaced" "w" "$(zd "$m/store.db-wal.zst")"

printf 'xx\n' > "$src/proj/gone-session-9.jsonl"
cat > "$VARVE_DATA/forgotten.toml" <<'T'
[[row]]
session_id = "session-9"
runtime = "alpha"
at = "2026-01-01"
T
"$sync" 2>/dev/null
want "forgotten not retained" "proj/one.jsonl" "$(rels "$m")"

# Shims on PATH: a zstd shim runs the real one, logs each compress, and can grow
# the watched source after the compress has read it.
realzstd="$(command -v zstd)"
shim="$tmp/shim"; mkdir -p "$shim"
cat > "$shim/zstd" <<S
#!/bin/sh
case " \$* " in *" -19 "*) echo "\$*" >> "\$SHIM_LOG" ;; esac
$realzstd "\$@" || exit \$?
case " \$* " in *" -19 "*)
  for last; do :; done
  if [ "\$last" = "\${SHIM_TRIG:-}" ] && [ "\$(cat "\$SHIM_TIMES")" -gt 0 ]; then
    echo \$((\$(cat "\$SHIM_TIMES") - 1)) > "\$SHIM_TIMES"
    printf x >> "\$last"
  fi ;;
esac
S
chmod +x "$shim/zstd"
export SHIM_LOG="$tmp/zlog" SHIM_TIMES="$tmp/times"
: > "$SHIM_LOG"; echo 0 > "$SHIM_TIMES"

# Equal mtime spawns no compress.
: > "$SHIM_LOG"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "equal mtime spawns nothing" "0" "$(wc -l < "$SHIM_LOG" | tr -d ' ')"

# A source deleted after sync leaves its lines.
rm -f "$src/proj/one.jsonl"
"$sync" 2>/dev/null
want "deleted source keeps its lines" "proj/one.jsonl" "$(rels "$m")"

# A replace pair that changes mid-compress ships as neither file.
export SHIM_TRIG="$src/store.db-wal"
printf 'db2\n' > "$src/store.db"; printf 'wal-two-longer\n' > "$src/store.db-wal"
echo 99 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>"$tmp/err"
want "unstable pair keeps old db" "db1" "$(zd "$m/store.db.zst")"
want "unstable pair keeps old wal" "w" "$(zd "$m/store.db-wal.zst")"
want "unstable pair is logged" "yes" "$(grep -q 'kept 2 unstable' "$tmp/err" && echo yes || echo no)"
want "unstable pair leaves no temp" "0" "$(find "$m" -name '*.tmp.*' | wc -l | tr -d ' ')"

echo 1 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "pair ships once stable (db)" "db2" "$(zd "$m/store.db.zst")"
want "pair ships once stable (wal)" "yes" "$(cmp -s "$src/store.db-wal" <(zd "$m/store.db-wal.zst") && echo yes || echo no)"
want "the pair renamed together: equal mtimes" "$(mtn "$src/store.db")|$(mtn "$src/store.db-wal")" "$(mtn "$m/store.db.zst")|$(mtn "$m/store.db-wal.zst")"

# The journal changing after the database was read (a checkpoint between the
# two) ships as neither file.
printf 'db-four\n' > "$src/store.db"
export SHIM_TRIG="$src/store.db"
echo 99 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>"$tmp/err"
want "checkpoint between reads keeps old db" "db2" "$(zd "$m/store.db.zst")"
want "checkpoint between reads is logged" "yes" "$(grep -q 'kept 2 unstable' "$tmp/err" && echo yes || echo no)"
echo 1 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "set ships once the journal settles" "yes" "$(cmp -s "$src/store.db" <(zd "$m/store.db.zst") && echo yes || echo no)"
unset SHIM_TRIG

# A journal the source no longer has leaves the mirror with the new database.
rm -f "$src/store.db-wal"; printf 'db5\n' > "$src/store.db"
"$sync" 2>/dev/null
want "vanished journal: new db shipped" "db5" "$(zd "$m/store.db.zst")"
want "vanished journal: mirror journal removed" "no" "$([ -e "$m/store.db-wal.zst" ] && echo yes || echo no)"

# A temp stranded by a killed run is swept at the next sync.
printf junk > "$m/store.db.zst.tmp.4242"
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
want "only the real file is retained" "real/in.jsonl" "$(rels "$b")"
want "symlinked dir not followed" "no" "$([ -e "$b/linkdir" ] && echo yes || echo no)"
want "symlinked replace entry not copied" "no" "$([ -e "$b/store.db.zst" ] && echo yes || echo no)"

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
