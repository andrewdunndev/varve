#!/usr/bin/env bash
# Cap self-test. Every bound runs twice: a tight run must exit 1 with the
# failure line, a control run of the same query must exit 0, so the cap and
# not the query did the killing.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_caps.XXXXXX)"
bg=""
cleanup() {
  if [ -n "$bg" ]; then kill "$bg" 2>/dev/null || true; fi
  rm -rf "$tmp"
  rm -f "$repo/bin/.lint-probe"
}
trap cleanup EXIT
export VARVE_DATA="$tmp/data"
export VARVE_LOCK="$tmp/lock"
unset VARVE_LOCK_PID VARVE_LAKE VARVE_PUBLISHED
duck="$repo/bin/duck"
fail=0

SORT="CREATE TEMP TABLE s AS SELECT i, hash(i) h FROM range(20000000) t(i) ORDER BY h;"
SPIN="SELECT sum(hash(i)) FROM range(2000000000) t(i);"

# check NAME WANT_RC WANT_TEXT OUT RC
verdict() {
  if [ "$4" != "$2" ] || { [ -n "$3" ] && ! printf '%s' "$5" | grep -q -- "$3"; }; then
    echo "FAIL: $1: want exit $2 matching '$3', got exit $4:" >&2
    printf '%s\n' "$5" | tail -5 >&2
    fail=1
  else
    echo "  ok: $1" >&2
  fi
}

# pair NAME CAP "TIGHT ENV" "CONTROL ENV" SQL
pair() {
  local out rc=0
  out="$(env $3 "$duck" "$1" -c "$5" 2>&1)" || rc=$?
  verdict "$1 tight" 1 "varve: $1 hit $2 " "$rc" "$out"
  rc=0
  out="$(env $4 "$duck" "$1" -c "$5" 2>&1)" || rc=$?
  verdict "$1 control" 0 "" "$rc" "$out"
}

pair memory_limit memory_limit "VARVE_MEMORY_LIMIT=32MB" "VARVE_MEMORY_LIMIT=2GB" "SET temp_directory=''; $SORT"
pair spill spill "VARVE_MEMORY_LIMIT=512MB VARVE_MAX_SPILL=8MB" "VARVE_MEMORY_LIMIT=512MB VARVE_MAX_SPILL=4GB" "$SORT"
pair rss "resident memory" "VARVE_MEMORY_LIMIT=2GB VARVE_MAX_RSS_MB=64 VARVE_WATCH_SECONDS=0.1" "VARVE_MEMORY_LIMIT=2GB VARVE_MAX_RSS_MB=4096 VARVE_WATCH_SECONDS=0.1" "$SORT"
pair wall "wall clock" "VARVE_WALL_SECONDS=1 VARVE_THREADS=1" "VARVE_WALL_SECONDS=120 VARVE_THREADS=1" "$SPIN"

# threads
for n in 1 2; do
  out="$(VARVE_THREADS=$n "$duck" threads -noheader -list -c "SELECT current_setting('threads')" 2>&1)" || true
  verdict "threads $n" 0 "^$n\$" 0 "$out"
done

# lock
VARVE_LOCK_PID= "$duck" locked sleep 4 &
bg=$!
i=0; while [ ! -f "$VARVE_LOCK/pid" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
rc=0; out="$("$duck" lock -c "SELECT 1" 2>&1)" || rc=$?
verdict "lock held" 1 "lock held by pid" "$rc" "$out"
wait "$bg" || true; bg=""
rc=0; out="$("$duck" lock -c "SELECT 1" 2>&1)" || rc=$?
verdict "lock released" 0 "" "$rc" "$out"
rc=0; out="$("$duck" locked "$duck" nested -c "SELECT 1" 2>&1)" || rc=$?
verdict "lock nested" 0 "" "$rc" "$out"
sleep 0 & dead=$!; wait "$dead"
mkdir "$VARVE_LOCK"; echo "$dead" > "$VARVE_LOCK/pid"
rc=0; out="$("$duck" lock -c "SELECT 1" 2>&1)" || rc=$?
verdict "lock dead pid stolen" 0 "" "$rc" "$out"

# priority
child_nice() {
  local c="$1"
  if [ -r "/proc/$c/stat" ]; then sed 's/^.*) //' "/proc/$c/stat" | awk '{print $17}'
  else ps -o ni= -p "$c" | tr -d ' '; fi
}
base="$(child_nice $$)"
for add in 10 0; do
  want=$((base + add))
  rm -f "$VARVE_LOCK/child"
  VARVE_NICE=$add VARVE_THREADS=1 "$duck" priority -c "$SPIN" >/dev/null 2>&1 &
  bg=$!
  i=0; while [ ! -s "$VARVE_LOCK/child" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 1
  got="$(child_nice "$(cat "$VARVE_LOCK/child")" || true)"
  kill "$bg" 2>/dev/null || true
  wait "$bg" 2>/dev/null || true; bg=""
  verdict "nice $want" 0 "^$want\$" 0 "$got"
done

# a run dir stranded by a SIGKILL is swept at the next lock; a live one is not
sleep 0 & gone=$!; wait "$gone"
mkdir -p "$VARVE_DATA/state/run.$gone/spill" "$VARVE_DATA/state/run.$$/spill"
echo spill > "$VARVE_DATA/state/run.$gone/spill/tmp"
rc=0; out="$("$duck" sweep -c "SELECT 1" 2>&1)" || rc=$?
verdict "sweep run" 0 "" "$rc" "$out"
verdict "sweep dead pid dir" 0 "^gone\$" 0 "$([ -e "$VARVE_DATA/state/run.$gone" ] && echo kept || echo gone)"
verdict "sweep live pid dir" 0 "^kept\$" 0 "$([ -e "$VARVE_DATA/state/run.$$" ] && echo kept || echo gone)"
rm -rf "$VARVE_DATA/state/run.$$"

# lint probe: the engine's name in a new code file must fail lint for that
# reason, in any case, and name the file
for word in "$(printf 'duck%s' db)" "$(printf 'Duck%s' DB)" "$(printf 'DUCK%s' DB)"; do
  echo "SELECT 1; -- $word" > "$repo/bin/.lint-probe"
  rc=0; err="$(cd "$repo" && just lint 2>&1 >/dev/null)" || rc=$?
  rm -f "$repo/bin/.lint-probe"
  if [ "$rc" = 0 ] || ! printf '%s' "$err" | grep -q 'the engine is named outside bin/duck' || ! printf '%s' "$err" | grep -q 'bin/.lint-probe'; then
    echo "FAIL: lint did not reject $word for naming the engine (exit $rc):" >&2; printf '%s\n' "$err" | tail -5 >&2; fail=1
  else
    echo "  ok: lint probe $word" >&2
  fi
done

exit $fail
