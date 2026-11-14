#!/usr/bin/env bash
# The Claude Code adapter over retained lines: an image payload is cut before any
# parse and nothing else is, a repeated line is read once, and the one-thread stages
# hand the runner's thread count back.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d -t varve_cclines.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
export VARVE_DATA="$tmp/data" VARVE_LOCK="$tmp/lock" VARVE_THREADS=2
unset VARVE_LOCK_PID VARVE_LAKE VARVE_PUBLISHED
duck="$repo/bin/duck"
fail=0

want() { # NAME EXPECTED ACTUAL
  if [ "$2" != "$3" ]; then echo "FAIL: $1: want '$2', got '$3'" >&2; fail=1; else echo "  ok: $1" >&2; fi
}

mkdir -p "$VARVE_DATA" "$tmp/mirror/lines/bucket=t"
for f in "$repo"/adapters/*.example.toml; do cp "$f" "$VARVE_DATA/$(basename "$f" .example.toml).toml"; done

# Four lines: a user message holding an image and a text block; the same line again
# in a second file; an assistant tool_use whose input has a long "data" value of its
# own; a tool_result holding an image.
"$duck" cc-lines -c "
COPY (
  WITH l(rel_path, line_no, line) AS (VALUES
    ('p/s.jsonl', 1, '{\"sessionId\":\"s1\",\"uuid\":\"u1\",\"type\":\"user\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"' || repeat('A', 2000000) || '\"}},{\"type\":\"text\",\"text\":\"look\"}]}}'),
    ('p/s-copy.jsonl', 1, '{\"sessionId\":\"s1\",\"uuid\":\"u1\",\"type\":\"user\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"' || repeat('A', 2000000) || '\"}},{\"type\":\"text\",\"text\":\"look\"}]}}'),
    ('p/s.jsonl', 2, '{\"sessionId\":\"s1\",\"uuid\":\"u2\",\"type\":\"assistant\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"message\":{\"role\":\"assistant\",\"id\":\"m1\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Send\",\"input\":{\"data\":\"' || repeat('B', 300) || '\"}}]}}'),
    ('p/s.jsonl', 3, '{\"sessionId\":\"s1\",\"uuid\":\"u3\",\"type\":\"user\",\"timestamp\":\"2026-01-01T00:00:02Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"' || repeat('C', 2000000) || '\"}},{\"type\":\"text\",\"text\":\"done\"}]}]}}'))
  SELECT * FROM l
) TO '$tmp/mirror/lines/bucket=t/d-1-0.parquet' (FORMAT parquet);"

q() { "$duck" cc-lines -noheader -list -c "SET VARIABLE mirror_dir='$tmp/mirror'" -f "$repo/sql/prelude.sql" -f "$repo/adapters/claude_code.sql" -c "$1"; }

want "payloads are cut, every line still parses" "4|4" \
  "$(q "SELECT count(*) FILTER (WHERE length(line) < 3000), count(*) FILTER (WHERE json_valid(line)) FROM _cc_line")"
want "an image block keeps its type and media type" "3" \
  "$(q "SELECT count(*) FROM _cc_line WHERE contains(line, '\"media_type\":\"image/png\",\"data\":\"\"')")"
want "a data value that is not an image payload is kept" "1" \
  "$(q "SELECT count(*) FROM _cc_line WHERE contains(line, repeat('B', 300))")"
want "a repeated line is one message" "u1,u2,u3" \
  "$(q "SELECT string_agg(message_id, ',' ORDER BY message_id) FROM stg_messages")"
want "message text beside an image" "look" "$(q "SELECT text FROM stg_messages WHERE message_id = 'u1'")"
want "a tool result beside an image" "done" "$(q "SELECT result_text FROM stg_tool_calls")"
want "the tool input is whole" "{\"data\":\"$(printf 'B%.0s' $(seq 1 300))\"}" "$(q "SELECT arguments FROM stg_tool_calls")"
want "the runner's thread count comes back" "2" "$(q "SELECT current_setting('threads')")"

[ "$fail" = 0 ] || exit 1
