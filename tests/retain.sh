#!/usr/bin/env bash
# Retention (ADR-0011): the line tables keep exactly the source bytes. Each case
# builds its own data home under a scratch directory; none touches the real one.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_retain.XXXXXX)"
trap 'rm -rf "${tmp:?}"' EXIT
export VARVE_LOCK="$tmp/lock" TZ=UTC
unset VARVE_MIRROR VARVE_LAKE VARVE_PUBLISHED VARVE_LOCK_PID VARVE_SYNC_NICED VARVE_CRASH
fail=0
want() {
  if [ "$2" != "$3" ]; then echo "FAIL: $1: want '$2', got '$3'" >&2; fail=1; else echo "  ok: $1" >&2; fi
}

# home NAME: a data home with one claude-code runtime reading $tmp/NAME/src.
# Sets d (data home), s (source), m (mirror folder of the runtime).
home() {
  d="$tmp/$1/data"; s="$tmp/$1/src"; m="$d/mirror/claude-code"
  mkdir -p "$d" "$s"
  for f in attribution pricing; do cp "$repo/adapters/$f.example.toml" "$d/$f.toml"; done
  printf '[[row]]\nname = "claude-code"\nadapter = "claude_code.sql"\nsource = "%s"\ninclude = ["*.jsonl"]\n' "$s" > "$d/runtimes.toml"
  export VARVE_DATA="$d"
}
sync() { "$repo/bin/sync" "$@" 2>"$tmp/err"; }
q() { "$repo/bin/duck" q -noheader -list "$@"; }
lines_glob() { echo "read_parquet('$m/lines/*/*.parquet', hive_partitioning = false)"; }
nrows() { q -c "SELECT count(*) FROM $(lines_glob);"; }
manifest() { q -c "SELECT $1 FROM read_parquet('$m/manifest.parquet') WHERE rel_path = '$2';"; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
tree_sums() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs shasum -a 256); }
# drop_row FILE REL LINE_NO: rewrite a parquet file without one row.
drop_row() {
  q -c "COPY (SELECT * FROM read_parquet('$1') WHERE NOT (rel_path = '$2' AND line_no = $3)) TO '$1.new' (FORMAT parquet);" > /dev/null
  mv "$1.new" "$1"
}
first_lines_file() { find "$m/lines" -name "$1" -print | LC_ALL=C sort | head -1; }

echo "varve test: retention (a) an append writes only the new lines" >&2
home a
printf 'l1\nl2\nl3\n' > "$s/f.jsonl"
sync
printf 'l4\nl5\n' >> "$s/f.jsonl"
sync
want "a: all five lines retained once" "5" "$(nrows)"
want "a: the second delta holds only the new lines" "2" "$(q -c "SELECT count(*) FROM read_parquet('$(first_lines_file 'd-2-*.parquet')', hive_partitioning = false);")"
want "a: the manifest hash is the source hash" "$(sha "$s/f.jsonl")" "$(manifest sha256 f.jsonl)"
want "a: reconstructed bytes equal the source" "1 of 1" "$("$repo/bin/sync" --verify 2>&1 | sed -n 's/.*verify \([0-9]*\) of \([0-9]*\) match.*/\1 of \2/p')"

echo "varve test: retention (b) a partial last line waits in the tail" >&2
home b
printf 'l1\nl2\npart' > "$s/f.jsonl"
sync
want "b: the partial line is not a line" "2" "$(nrows)"
want "b: the partial line is the tail" "part" "$(manifest tail f.jsonl)"
want "b: retained bytes cover the tail" "10" "$(manifest bytes f.jsonl)"
printf 'ial\nl4\n' >> "$s/f.jsonl"
sync
want "b: the completed line joins the lines" "4" "$(nrows)"
want "b: the completed line is whole" "partial" "$(q -c "SELECT line FROM $(lines_glob) WHERE line_no = 3;")"
want "b: no tail remains" "" "$(manifest "coalesce(tail, '')" f.jsonl)"
want "b: the hash is the source hash" "$(sha "$s/f.jsonl")" "$(manifest sha256 f.jsonl)"

echo "varve test: retention (c) a rewritten source keeps its retained bytes" >&2
home c
printf 'aaaa\nbbbb\ncccc\n' > "$s/f.jsonl"
sync
before="$(manifest sha256 f.jsonl)"
printf 'aaaa\n' > "$s/f.jsonl"; touch -t 203001010000 "$s/f.jsonl"
sync
want "c: shorter source is diverged" "diverged" "$(manifest status f.jsonl)"
want "c: shorter source keeps its bytes" "$before" "$(manifest sha256 f.jsonl)"
want "c: shorter source is named" "yes" "$(grep -q 'diverged' "$tmp/err" && echo yes || echo no)"
printf 'aaaa\nBBBB\ncccc\ndddd\n' > "$s/f.jsonl"; touch -t 203101010000 "$s/f.jsonl"
sync
want "c: longer source with another prefix is diverged" "diverged" "$(manifest status f.jsonl)"
want "c: retained lines unchanged" "3" "$(nrows)"
want "c: still verifies as the old bytes" "1 of 1" "$("$repo/bin/sync" --verify 2>&1 | sed -n 's/.*verify \([0-9]*\) of \([0-9]*\) match.*/\1 of \2/p')"

echo "varve test: retention (d) a crash between the delta rename and the manifest rename" >&2
home d
printf 'b1\nb2\n' > "$s/b.jsonl"; touch -t 202601050000 "$s/b.jsonl"
sync
printf 'a1\na2\na3\n' > "$s/a.jsonl"; touch -t 202603050000 "$s/a.jsonl"
rc=0; VARVE_CRASH=delta sync || rc=$?
want "d: the crash stops the run" "9" "$rc"
want "d: the manifest is still the old one" "b.jsonl" "$(q -c "SELECT string_agg(rel_path, ',') FROM read_parquet('$m/manifest.parquet');")"
rm "$s/a.jsonl"
printf 'c1\n' > "$s/c.jsonl"; touch -t 202604050000 "$s/c.jsonl"
sync
want "d: lines equal the manifest" "$(q -c "SELECT sum(lines) FROM read_parquet('$m/manifest.parquet');")" "$(nrows)"
want "d: the orphaned delta is gone" "0" "$(q -c "SELECT count(*) FROM $(lines_glob) WHERE rel_path = 'a.jsonl';")"
want "d: no duplicate rows" "$(nrows)" "$(q -c "SELECT count(DISTINCT (rel_path, line_no)) FROM $(lines_glob);")"

echo "varve test: retention (e) compaction refuses a bucket that does not match the manifest" >&2
home e
printf 'l1\nl2\n' > "$s/f.jsonl"; sync
printf 'l3\nl4\n' >> "$s/f.jsonl"; sync
bucket="$(manifest bucket f.jsonl)"
drop_row "$(first_lines_file 'd-1-*.parquet')" f.jsonl 1
files_before="$(tree_sums "$m")"
rc=0; "$repo/bin/lines" compact "$m" "$bucket" 2>"$tmp/err" || rc=$?
want "e: compact refuses" "yes" "$([ "$rc" -ne 0 ] && echo yes || echo no)"
want "e: the old files stay" "$files_before" "$(tree_sums "$m")"

echo "varve test: retention (g) a file that is not UTF-8 is counted and retried" >&2
home g
printf 'ok\n' > "$s/good.jsonl"
printf 'bad \377 byte\n' > "$s/bad.jsonl"
sync
want "g: counted as unretained" "yes" "$(grep -q 'unretained 1' "$tmp/err" && echo yes || echo no)"
want "g: only the good file is retained" "good.jsonl" "$(q -c "SELECT string_agg(rel_path, ',') FROM read_parquet('$m/manifest.parquet');")"
sync
want "g: retried on the next sync" "yes" "$(grep -q 'unretained 1' "$tmp/err" && echo yes || echo no)"
printf 'fixed\n' > "$s/bad.jsonl"
sync
want "g: retained once it is valid" "bad.jsonl,good.jsonl" "$(q -c "SELECT string_agg(rel_path, ',' ORDER BY rel_path) FROM read_parquet('$m/manifest.parquet');")"

echo "varve test: retention (h) an unchanged tree spawns no engine" >&2
home h
printf 'l1\n' > "$s/f.jsonl"
eng="duck""db"
realmise="$(command -v mise || true)"
shim="$tmp/shim"; mkdir -p "$shim"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$tmp/mise.log" "${realmise:-/usr/bin/false}" > "$shim/mise"
chmod +x "$shim/mise"
: > "$tmp/mise.log"
PATH="$shim:$PATH" "$repo/bin/sync" 2>/dev/null
want "h: a changed tree starts the engine" "yes" "$(grep -q "$eng" "$tmp/mise.log" && echo yes || echo no)"
: > "$tmp/mise.log"
PATH="$shim:$PATH" "$repo/bin/sync" 2>/dev/null
want "h: an unchanged tree does not" "0" "$(grep -c "$eng" "$tmp/mise.log" | tr -d ' ')"

echo "varve test: retention (i) size: a corpus of 3MB retains at under 40%" >&2
home i
mkdir -p "$s/p"
awk 'BEGIN { srand(7); for (f = 0; f < 6; f++) { out = sprintf("'"$s"'/p/s%d.jsonl", f);
  for (n = 0; n < 1500; n++) { t = "";
    for (w = 0; w < 40; w++) t = t sprintf("w%d ", int(rand() * 900));
    printf "{\"type\":\"user\",\"uuid\":\"%08x\",\"timestamp\":\"2026-11-01T00:00:%02d.000Z\",\"message\":{\"role\":\"user\",\"content\":\"%s\"}}\n", int(rand() * 4e9), n % 60, t > out } } }'
sync --compact
plain="$(find "$s" -name '*.jsonl' -exec cat {} + | wc -c | tr -d ' ')"
kept="$(find "$m" -type f -exec cat {} + | wc -c | tr -d ' ')"
want "i: the retained form is under 40% of the plain bytes ($kept of $plain)" "yes" "$([ $((kept * 100)) -lt $((plain * 40)) ] && echo yes || echo no)"

# proofs: two real fixture sessions, in different weeks
proof_home() {
  home "$1"
  mkdir -p "$s/testproj"
  cp "$repo/tests/fixtures/mirror/claude-code/testproj/session-scope.jsonl" "$s/testproj/test-session-scope.jsonl"
  cp "$repo/tests/fixtures/mirror/claude-code/testproj/session-2023.jsonl" "$s/testproj/test-session-2023.jsonl"
  touch -t 202601050000 "$s/testproj/test-session-scope.jsonl"
  touch -t 202603050000 "$s/testproj/test-session-2023.jsonl"
  mkdir -p "$d/checks"
  export VARVE_LAKE="$d/lake"
}
build() { "$repo/bin/duck" locked "$repo/bin/build" 2>"$tmp/build.err"; }
counts() { q -c "SELECT (SELECT count(DISTINCT session_id) FROM sessions) || '/' || (SELECT count(*) FROM messages) || '/' || (SELECT count(*) FROM api_calls) || '/' || (SELECT count(*) FROM tool_calls);"; }

echo "varve test: retention (f) forget rewrites only its own bucket" >&2
proof_home f
sync; build || { tail -5 "$tmp/build.err" >&2; fail=1; }
other="$(manifest bucket testproj/test-session-2023.jsonl)"
mine="$(manifest bucket testproj/test-session-scope.jsonl)"
want "f: the two sessions sit in different buckets" "yes" "$([ "$other" != "$mine" ] && echo yes || echo no)"
other_before="$(tree_sums "$m/lines/bucket=$other"; stat -f %m "$m/lines/bucket=$other"/* 2>/dev/null || stat -c %Y "$m/lines/bucket=$other"/*)"
"$repo/bin/duck" locked "$repo/bin/forget" test-session-scope 2>"$tmp/forget.err" || { tail -5 "$tmp/forget.err" >&2; fail=1; }
want "f: the other bucket is untouched" "$other_before" "$(tree_sums "$m/lines/bucket=$other"; stat -f %m "$m/lines/bucket=$other"/* 2>/dev/null || stat -c %Y "$m/lines/bucket=$other"/*)"
want "f: the session's lines are gone" "0" "$(q -c "SELECT count(*) FROM $(lines_glob) WHERE contains(rel_path, 'test-session-scope');")"
want "f: the session is gone from the lake" "0" "$(q -c "SELECT count(*) FROM sessions WHERE session_id = 'test-session-scope';")"

echo "varve test: retention (j, k) a session deleted at its source; the lake rebuilt from the lines alone" >&2
proof_home j
sync; build || { tail -5 "$tmp/build.err" >&2; fail=1; }
c0="$(counts)"
rm -rf "${s:?}/testproj"
sync
want "j: the lines still answer in SQL" "yes" "$([ "$(q -c "SELECT count(*) FROM $(lines_glob) WHERE contains(rel_path, 'test-session-scope');")" -gt 0 ] && echo yes || echo no)"
build || { tail -5 "$tmp/build.err" >&2; fail=1; }
want "j: the session is still in the lake" "1" "$(q -c "SELECT count(*) FROM sessions WHERE session_id = 'test-session-scope';")"
want "j: counts are unchanged" "$c0" "$(counts)"
rm -rf "${d:?}/lake" "${d:?}/lake.old"
build || { tail -5 "$tmp/build.err" >&2; fail=1; }
want "k: the lake rebuilds from the retained lines alone" "$c0" "$(counts)"
want "k: and is not empty" "yes" "$([ "$c0" != "0/0/0/0" ] && echo yes || echo no)"
unset VARVE_LAKE

echo "varve test: retention (l) every retained file reconstructs to its source bytes" >&2
home l
export VARVE_MIRROR="$d/mirror"
mkdir -p "$VARVE_MIRROR/claude-code/p"
cp "$repo/tests/fixtures/mirror/claude-code/testproj/session-scope.jsonl" "$VARVE_MIRROR/claude-code/p/x.jsonl"
cp "$repo/tests/fixtures/mirror/claude-code/testproj/session-2023.jsonl" "$VARVE_MIRROR/claude-code/p/y.jsonl"
"$repo/bin/pack" 2>/dev/null
rc=0; "$repo/bin/pack" --verify 2>"$tmp/err" || rc=$?
want "l: pack --verify passes" "0" "$rc"
want "l: pack --verify counts every file" "yes" "$(grep -q 'verify 2 of 2 match' "$tmp/err" && echo yes || echo no)"
rc=0; "$repo/bin/sync" --verify 2>"$tmp/err" || rc=$?
want "l: sync --verify passes" "0" "$rc"
printf 'extra\n' > "$VARVE_MIRROR/claude-code/p/z.jsonl"
rc=0; "$repo/bin/pack" --verify 2>/dev/null || rc=$?
want "l: pack --verify fails on a plain file with no twin" "1" "$rc"
"$repo/bin/pack" 2>/dev/null
drop_row "$(find "$m/lines" -name '*.parquet' -print -quit)" p/x.jsonl 1
rc=0; "$repo/bin/pack" --verify 2>/dev/null || rc=$?
want "l: pack --verify fails on a mutated row" "1" "$rc"
rc=0; "$repo/bin/sync" --verify 2>/dev/null || rc=$?
want "l: sync --verify fails on a mutated row" "1" "$rc"
unset VARVE_MIRROR

exit $fail
