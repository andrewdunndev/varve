#!/usr/bin/env bash
# bin/sync: grow-only compressed copy, allow-list, forgotten sessions, replace set.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_sync.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export VARVE_DATA="$tmp/data" VARVE_LOCK="$tmp/lock"
unset VARVE_MIRROR VARVE_SYNC_NICED
sync="$repo/bin/sync"
src="$tmp/src"
fail=0
zd() { zstd -dc "$1"; }
mtn() { if stat --version >/dev/null 2>&1; then stat -c %.9Y "$1"; else stat -f %Fm "$1"; fi; }

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
want "copied, retained as a frame" "aaaa" "$(zd "$m/proj/one.jsonl.zst")"
want "the frame holds no plain twin" "no" "$([ -e "$m/proj/one.jsonl" ] && echo yes || echo no)"
want "the frame carries the source mtime" "$(mtn "$src/proj/one.jsonl")" "$(mtn "$m/proj/one.jsonl.zst")"
want "sibling not copied" "no" "$([ -e "$m/proj/.credentials.json" ] && echo yes || echo no)"
want "replace pair copied" "db1 wal-long" "$(zd "$m/store.db.zst") $(zd "$m/store.db-wal.zst")"

printf 'aa\n' > "$src/proj/one.jsonl"
"$sync" 2>"$tmp/err"
want "shorter source is loud" "yes" "$(grep -q "shorter than its retained copy" "$tmp/err" && echo yes || echo no)"
want "shorter source counted" "yes" "$(grep -q "skipped 1 shorter" "$tmp/err" && echo yes || echo no)"
want "shorter source kept" "aaaa" "$(zd "$m/proj/one.jsonl.zst")" "aaaa" "$(zd "$m/proj/one.jsonl.zst")"

printf 'aaaaaaaa\n' > "$src/proj/one.jsonl"
"$sync" 2>/dev/null
want "longer source recompressed" "aaaaaaaa" "$(zd "$m/proj/one.jsonl.zst")"
want "longer source frame is whole" "yes" "$(cmp -s "$src/proj/one.jsonl" <(zd "$m/proj/one.jsonl.zst") && echo yes || echo no)"

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
want "forgotten not copied" "no" "$([ -e "$m/proj/gone-session-9.jsonl.zst" ] && echo yes || echo no)"


# Shims on PATH: a zstd shim
# runs the real one, logs each compress, and can grow the watched source after
# the compress has read it.
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

# Equal mtime spawns no compress and no second look at a frame.
: > "$SHIM_LOG"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "equal mtime spawns nothing" "0" "$(wc -l < "$SHIM_LOG" | tr -d ' ')"

# A source that changes mid-compress is retried, then kept.
printf 'cccccccccccc\n' > "$src/proj/one.jsonl"
export SHIM_TRIG="$src/proj/one.jsonl"
echo 99 > "$SHIM_TIMES"; : > "$SHIM_LOG"
PATH="$shim:$PATH" "$sync" 2>"$tmp/err"
want "unstable file keeps the old frame" "aaaaaaaa" "$(zd "$m/proj/one.jsonl.zst")"
want "unstable file is logged" "yes" "$(grep -q 'kept 1 unstable' "$tmp/err" && echo yes || echo no)"
want "unstable file tried three times" "3" "$(grep -c -- "$src/proj/one.jsonl" "$SHIM_LOG" | tr -d ' ')"
echo 1 > "$SHIM_TIMES"
PATH="$shim:$PATH" "$sync" 2>/dev/null
want "unstable file ships once it settles" "yes" "$(cmp -s "$src/proj/one.jsonl" <(zd "$m/proj/one.jsonl.zst") && echo yes || echo no)"
unset SHIM_TRIG

# A source deleted after sync leaves its frame.
rm -f "$src/proj/one.jsonl"
"$sync" 2>/dev/null
want "deleted source keeps its frame" "yes" "$([ -s "$m/proj/one.jsonl.zst" ] && echo yes || echo no)"
printf 'aaaaaaaa\n' > "$src/proj/one.jsonl"; touch -r "$m/proj/one.jsonl.zst" "$src/proj/one.jsonl"

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

# A source rewritten shorter, newer mtime: the frame stays, the run says so.
zd "$m/proj/one.jsonl.zst" > "$tmp/before"
printf 'bb\n' > "$src/proj/one.jsonl"
"$sync" 2>"$tmp/err"
want "rewritten-shorter keeps the frame" "yes" "$(cmp -s "$tmp/before" <(zd "$m/proj/one.jsonl.zst") && echo yes || echo no)"
want "rewritten-shorter is named" "yes" "$(grep -q 'proj/one.jsonl is shorter than its retained copy' "$tmp/err" && echo yes || echo no)"
want "no temp left behind" "0" "$(find "$m" -name '*.tmp.*' | wc -l | tr -d ' ')"

# A temp stranded by a killed run is swept at the next sync.
printf junk > "$m/proj/one.jsonl.zst.tmp.4242"
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
want "real file copied" "inside" "$(zd "$b/real/in.jsonl.zst")"
want "symlinked file not copied" "no" "$([ -e "$b/real/link.jsonl.zst" ] && echo yes || echo no)"
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
