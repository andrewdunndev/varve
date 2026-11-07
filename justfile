# varve -- local agent-session record lake (Parquet + DuckDB).
# Data home: ~/.local/share/varve (never in this repo; VARVE_DATA overrides).
# Zero resident processes: every target is invoke-and-exit. Every SQL run goes
# through bin/duck, which bounds it and serializes writers.

# Recipe args reach recipes as "$@" with quoting intact ({{ARGS}} interpolation
# would re-split quoted SQL at the shell).
set positional-arguments

data_home := env_var_or_default("VARVE_DATA", env_var("HOME") + "/.local/share/varve")
repo      := justfile_directory()
lake      := env_var_or_default("VARVE_LAKE", data_home + "/lake")
state     := data_home + "/state"
# Adjudication ledger and worksheet: operator data in the data home, never in the
# repo. A missing file is a missing ledger; `mine` and `review` handle absence.
adjudications := data_home + "/adjudications.jsonl"
worksheet     := data_home + "/adjudication_worksheet.jsonl"

default:
    @just --list

# Copy runtime sources into the mirror (no engine, nice 19).
sync:
    {{repo}}/bin/sync

# Rebuild the lake from the mirror: one process per runtime into lake.new, the
# checks, a swap by rename, then the mines. A failed runtime keeps its last good
# partitions. Needs runtimes.toml, attribution.toml and pricing.toml in the data
# home (copy the *.example.toml files and edit).
build:
    {{repo}}/bin/duck locked {{repo}}/bin/build

# Run every check (checks/ in the repo, then checks/ in the data home) against
# the published lake. Each failure line names the next action.
check:
    {{repo}}/bin/check

# Drop a session from the mirror and the lake for good, then rebuild. The one
# way a session leaves the record.
forget id:
    {{repo}}/bin/duck locked {{repo}}/bin/forget "$1"

# Correction mining. Rebuilds correction_candidates (four detectors, precision-first),
# operator_messages (recall-floor denominator: metadata-only, flagged = also a candidate
# locus) and promotes adjudicated candidates into correction_events, all purely from the
# lake, so the rebuild is deterministic. `build` calls this after the swap. The
# adjudication ledger is operator data in the data home; when absent, an empty temp file
# is substituted so the read never errors and zero events promote. Ends by running the
# checks, so the ledger is tested against the fresh candidates. COPY targets are
# literals here (COPY TO cannot take getvariable).
mine:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{lake}}/messages" ]; then
      echo "varve: skip mine -- no core tables at {{lake}}" >&2; exit 0
    fi
    adj="{{adjudications}}"
    tmp=""
    if [ ! -f "$adj" ]; then tmp="$(mktemp -t varve_adj.XXXXXX)"; adj="$tmp"; fi
    # Full-rebuild semantics need a clean target: these three are pure derivations
    # of the lake, and OVERWRITE_OR_IGNORE only replaces partitions the new run
    # writes -- a (runtime, date) partition that becomes EMPTY after a detector
    # change would otherwise survive as stale rows.
    rm -rf "{{lake}}/correction_candidates" "{{lake}}/operator_messages" "{{lake}}/correction_events"
    {{repo}}/bin/duck mine \
      -c "SET VARIABLE lake='{{lake}}'; SET VARIABLE repo_dir='{{repo}}'; SET VARIABLE adjudications='$adj';" \
      -f "{{repo}}/mining/corrections.sql" \
      -c "COPY (SELECT * FROM stg_correction_candidates ORDER BY runtime, date, candidate_id) TO '{{lake}}/correction_candidates' (FORMAT parquet, PARTITION_BY (runtime, date), FILENAME_PATTERN 'part', OVERWRITE_OR_IGNORE, COMPRESSION zstd);" \
      -c "COPY (SELECT * FROM stg_operator_messages ORDER BY runtime, date, message_uuid) TO '{{lake}}/operator_messages' (FORMAT parquet, PARTITION_BY (runtime, date), FILENAME_PATTERN 'part', OVERWRITE_OR_IGNORE, COMPRESSION zstd);" \
      -c "COPY (SELECT * FROM stg_correction_events ORDER BY channel, date, event_id) TO '{{lake}}/correction_events' (FORMAT parquet, PARTITION_BY (channel, date), FILENAME_PATTERN 'part', OVERWRITE_OR_IGNORE, COMPRESSION zstd);"
    [ -n "$tmp" ] && rm -f "$tmp" || true
    {{repo}}/bin/check

# Adjudication review document. Renders the review sitting to
# <data_home>/review_round1.md (override with `out=`): one section per flagged correction
# candidate carrying the FULL prior draft + FULL corrective message + the model's advisory
# suggestion from the worksheet (context_judgment is largely un-inferable
# from a 240-char excerpt, so the review dereferences the full loci), then the recall-floor
# sample (unflagged operator messages) as a second part. Candidates/loci already in the
# adjudications ledger are SKIPPED, so the doc shrinks as the operator works through it
# (idempotent re-render). CONFIDENTIALITY: the ONLY output is the markdown under the data
# home; mining/review.sql holds zero transcript content, loci are the `lake:` form, and
# nothing is printed to a terminal. The worksheet is advisory operator data outside the repo
# (see `worksheet`); absence is non-fatal (a non-matching sentinel primes read_json_auto).
# The adjudication ledger is handled like `mine` (empty temp file when absent). COPY target
# is a literal here (COPY TO cannot take getvariable), matching how `mine` writes.
review out=(data_home + "/review_round1.md"):
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -d "{{lake}}/correction_candidates" ]; then
      echo "varve: skip review -- no correction_candidates at {{lake}} (run just mine first)" >&2; exit 0
    fi
    adj="{{adjudications}}"; adjtmp=""
    if [ ! -f "$adj" ]; then adjtmp="$(mktemp -t varve_adj.XXXXXX)"; adj="$adjtmp"; fi
    ws="{{worksheet}}"; wstmp=""
    if [ ! -s "$ws" ]; then
      # Absent/empty worksheet: prime read_json_auto with a non-matching sentinel row so the
      # advisory LEFT JOIN yields nothing (worksheet absence is non-fatal).
      wstmp="$(mktemp -t varve_ws.XXXXXX)"
      printf '%s\n' '{"candidate_id":"__no_worksheet__","detector":"","suggested_verdict":"","suggested_context_judgment":"","rationale":"","suggested_by":"","model_id":"","suggested_at":""}' > "$wstmp"
      ws="$wstmp"
    fi
    mkdir -p "$(dirname "{{out}}")"
    {{repo}}/bin/duck review \
      -c "SET VARIABLE lake='{{lake}}'; SET VARIABLE adjudications='$adj'; SET VARIABLE worksheet='$ws';" \
      -f "{{repo}}/mining/review.sql" \
      -c "COPY (SELECT md FROM stg_review_document ORDER BY part, ord2, ord3) TO '{{out}}' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\t');"
    [ -n "$adjtmp" ] && rm -f "$adjtmp" || true
    [ -n "$wstmp" ] && rm -f "$wstmp" || true
    echo "varve: wrote review -> {{out}}" >&2

# Intervention timeline for "does baking a correction into a rule stop it recurring",
# recovered from a rulebook's own git history, no new capture surface. GENERIC:
# rulebook_dir is any git repo the operator points this at; nothing here names a real path.
# Read-only -- shells `git log`, never writes to rulebook_dir; safe against a dirty
# working tree. Idempotent -- full rewrite of interventions.csv every run.
# Writes <data_home>/state/interventions.csv:
#   intervention_ref : commit sha            bake_date : ISO committer date (%cI)
#   rule_path        : one row per file touched (one row per commit x file)
#   subject          : commit subject line
# Usage: just interventions ~/path/to/rulebook-repo
interventions rulebook_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{state}}"
    out="{{state}}/interventions.csv"
    tmp="$(mktemp -t varve_interventions.XXXXXX)"
    printf 'intervention_ref,bake_date,rule_path,subject\n' > "$tmp"
    git -C "$1" log --format='%H%x09%cI%x09%s' --name-only --reverse | awk -F'\t' '
      NF == 3 { href = $1; date = $2; subj = $3; next }
      NF == 1 && $1 != "" {
        s = subj; gsub(/"/, "\"\"", s)
        p = $1;   gsub(/"/, "\"\"", p)
        printf "%s,%s,\"%s\",\"%s\"\n", href, date, p, s
      }
    ' >> "$tmp"
    mv "$tmp" "$out"
    echo "varve: wrote $(($(wc -l < "$out") - 1)) row(s) -> $out" >&2

# Open the engine with a view per lake folder. Pass args, e.g.
#   just sql -c "SELECT count(*) FROM api_calls;"
#   just sql -f queries/burn_by_day.sql
sql *ARGS:
    {{repo}}/bin/duck sql "$@"

# Year in review: a local-time activity heatmap plus year totals (ADR-0007).
#   just stats [--year N] [--runtime claude|pi|opencode|all] [--metric prompts|steps|tokens]
# VARVE_TODAY (YYYY-MM-DD) pins "today" for the current-year cut.
stats *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    year="$(date +%Y)"; runtime=all; metric=prompts
    while [ $# -gt 0 ]; do
      case "$1" in
        --year|--runtime|--metric)
          [ $# -ge 2 ] || { echo "varve stats: $1 needs a value" >&2; exit 2; }
          printf -v "${1#--}" '%s' "$2"; shift 2 ;;
        --year=*|--runtime=*|--metric=*)
          key="${1%%=*}"; printf -v "${key#--}" '%s' "${1#*=}"; shift ;;
        *) echo "varve stats: unknown argument $1" >&2; exit 2 ;;
      esac
    done
    [[ "$year" =~ ^[0-9]{4}$ ]] || { echo "varve stats: --year takes a four-digit year" >&2; exit 2; }
    case "$runtime" in claude|pi|opencode|all) ;; *) echo "varve stats: --runtime takes claude|pi|opencode|all" >&2; exit 2 ;; esac
    case "$metric" in prompts|steps|tokens) ;; *) echo "varve stats: --metric takes prompts|steps|tokens" >&2; exit 2 ;; esac
    today="${VARVE_TODAY:-$(date +%F)}"
    {{repo}}/bin/duck stats -noheader -list \
      -c "SET VARIABLE lake='{{lake}}'; SET VARIABLE year=$year; SET VARIABLE runtime='$runtime'; SET VARIABLE metric='$metric'; SET VARIABLE today=DATE '$today';" \
      -c ".output /dev/null" -f "{{repo}}/mining/queries/stats_year.sql" \
      -c ".output" -f "{{repo}}/mining/stats_render.sql"

# Report lake size; tripwire at ~100 GB (PRD D4: keep-everything is cheap
# at this scale, the watch is the control).
disk:
    @du -sh {{data_home}} 2>/dev/null || echo "no lake yet at {{data_home}}"
    @kb="$(du -sk {{data_home}} 2>/dev/null | cut -f1)"; if [ "${kb:-0}" -ge 104857600 ]; then echo "varve disk: TRIPWIRE -- data home exceeds ~100 GB (PRD D4 disk watch)"; fi

# CI/local lint. `just --evaluate` parses every recipe body and evaluates the
# top-level assignments, so a broken interpolation or recipe declaration fails
# here. Scripts under bin/ must parse. The engine's name appears nowhere
# outside the runner, the toolchain pin and prose: every run goes through
# bin/duck, which owns the bounds.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    just --evaluate > /dev/null
    for s in bin/* tests/*.sh; do bash -n "$s"; done
    word="duck""db"
    hits="$(find . -type f -not -path './.git/*' -not -path './docs/*' -not -path './golden-out/*' -not -path './bin/duck' -not -name mise.toml -not -name '*.md' -not -name '*.svg' -not -name '*.png' -exec grep -Ilw "$word" {} + || true)"
    if [ -n "$hits" ]; then
      echo "varve lint: the engine is named outside bin/duck:" >&2
      echo "$hits" >&2
      exit 1
    fi
    echo "varve lint: OK"

# CI/local test: a build over fixtures. The mirror fixtures go through the real
# build under a scratch VARVE_DATA, so the operator's lake is never touched.
# Assertions are checks. Then every query and the review run against the result,
# outputs are diffed against tests/golden and tests/snapshots, and the behavior
# tests break things on purpose: a failing adapter, a bound hit, a lost session.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -d -t varve_test.XXXXXX)"
    trap 'rm -rf "$tmp"' EXIT
    export VARVE_DATA="$tmp/data"
    export VARVE_MIRROR="$tmp/mirror"
    export VARVE_LOCK="$tmp/lock"
    export TZ=UTC
    unset VARVE_LAKE VARVE_PUBLISHED VARVE_LOCK_PID
    lake="$VARVE_DATA/lake"

    mkdir -p "$VARVE_DATA/checks" "$VARVE_MIRROR"
    cp -R "{{repo}}/tests/fixtures/mirror/." "$VARVE_MIRROR/"
    mkdir -p "$VARVE_MIRROR/opencode"
    echo "varve test: seeding synthetic opencode fixture db" >&2
    {{repo}}/bin/duck seed \
      -c "INSTALL sqlite; LOAD sqlite; ATTACH '$VARVE_MIRROR/opencode/opencode.db' AS oc (TYPE sqlite);" \
      -f "{{repo}}/tests/fixtures/opencode_seed.sql"
    for f in "{{repo}}"/adapters/*.example.toml; do
      cp "$f" "$VARVE_DATA/$(basename "$f" .example.toml).toml"
    done
    cp "{{repo}}/tests/fixtures/runtimes.toml" "$VARVE_DATA/runtimes.toml"
    cp "{{repo}}"/tests/checks/build/*.sql "$VARVE_DATA/checks/"

    echo "varve test: build over the synthetic mirror" >&2
    just build
    cp "{{repo}}"/tests/checks/mined/*.sql "$VARVE_DATA/checks/"
    just check

    echo "varve test: executing every queries/*.sql and mining/queries/*.sql against the fixture" >&2
    # Output of each query, each lake table and the review document is written to
    # golden-out/ (a CI artifact) and diffed against tests/golden/. Lines are sorted
    # so a query without ORDER BY cannot flake the comparison.
    gold="{{repo}}/golden-out"
    rm -rf "$gold"; mkdir -p "$gold"
    fail=0
    for f in "{{repo}}"/queries/*.sql "{{repo}}"/mining/queries/*.sql; do
      echo "  -- $f" >&2
      case "$f" in
        "{{repo}}"/mining/*) name="mining_$(basename "$f" .sql).csv" ;;
        *) name="query_$(basename "$f" .sql).csv" ;;
      esac
      if ! just sql -csv -c "SET VARIABLE repo='{{repo}}';" -f "$f" | LC_ALL=C sort > "$gold/$name"; then
        echo "FAIL: $f did not execute cleanly" >&2
        fail=1
      fi
    done
    for t in sessions messages api_calls tool_calls correction_candidates operator_messages; do
      if ! just sql -csv -c "SELECT * FROM $t ORDER BY ALL;" | LC_ALL=C sort > "$gold/table_$t.csv"; then
        echo "FAIL: could not dump table $t" >&2
        fail=1
      fi
    done

    echo "varve test: just review (mining/review.sql)" >&2
    just review "$tmp/review.md" > /dev/null
    sed -E 's/_Generated [0-9: -]+\./_Generated <ts>./' "$tmp/review.md" > "$gold/review.md"

    echo "varve test: just stats (snapshot, year-boundary streak, empty year, runtime filter)" >&2
    export VARVE_TODAY=2026-10-13
    if ! just stats --year 2026 | diff -u "{{repo}}/tests/snapshots/stats_2026.txt" - >&2; then
      echo "FAIL: just stats --year 2026 differs from tests/snapshots/stats_2026.txt" >&2
      fail=1
    fi
    stats_tail() {
      local want="$1"; shift
      local got; got="$(just stats "$@" | tail -3)"
      if [ "$got" != "$want" ]; then
        echo "FAIL: just stats $* ended with:" >&2; printf '%s\n' "$got" >&2
        fail=1
      fi
    }
    stats_tail $'1 session · 0 subagents\n2 prompts · 3 steps · 4.7k tokens · $0.00\n100.0% tool success · 2 active days · best streak 2 days' --year 2025
    stats_tail $'0 sessions · 0 subagents\n0 prompts · 0 steps · 0 tokens · $0.00\nn/a tool success · 0 active days · best streak 0 days' --year 2024
    stats_tail $'1 session · 0 subagents\n1 prompt · 1 step · 150 tokens · $0.00\n100.0% tool success · 1 active day · best streak 1 day' --year 2026 --runtime pi

    echo "varve test: golden outputs (tests/golden)" >&2
    if [ -n "${VARVE_GOLDEN_CAPTURE:-}" ]; then
      echo "  capture mode: golden-out/ is the artifact, no comparison" >&2
    elif [ ! -d "{{repo}}/tests/golden" ]; then
      echo "FAIL: tests/golden is missing; capture golden-out/ from a CI run" >&2
      fail=1
    elif ! diff -ru "{{repo}}/tests/golden" "$gold" > "$tmp/golden.diff"; then
      echo "FAIL: output differs from tests/golden (first 60 lines of the diff):" >&2
      head -60 "$tmp/golden.diff" >&2
      fail=1
    fi

    echo "varve test: runner caps, startup views and sync" >&2
    {{repo}}/tests/caps.sh || fail=1
    {{repo}}/tests/views.sh || fail=1
    {{repo}}/tests/sync.sh || fail=1

    echo "varve test: build behavior" >&2
    sums() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs cksum); }
    rm -f "$VARVE_DATA/checks/"{candidates_present,copy_owner,detectors}.sql

    # A runtime whose adapter fails keeps its published partitions; the others rebuild.
    mkdir -p "$VARVE_DATA/adapters"
    echo "SELECT * FROM no_such_table;" > "$VARVE_DATA/adapters/pi.sql"
    pi_before="$(sums "$lake/messages/runtime=pi")"
    rm -rf "$lake/messages/runtime=opencode"
    rc=0; just build 2>"$tmp/build.err" || rc=$?
    if [ "$rc" -ne 1 ]; then echo "FAIL: a failing adapter should exit the build 1, got $rc" >&2; fail=1; fi
    if [ "$(sums "$lake/messages/runtime=pi")" != "$pi_before" ]; then
      echo "FAIL: the failed runtime's published partitions changed" >&2; fail=1
    fi
    if [ ! -d "$lake/messages/runtime=opencode" ]; then
      echo "FAIL: the other runtimes were not rebuilt around the failure" >&2; fail=1
    fi
    rm -rf "$VARVE_DATA/adapters"

    # A bound hit abandons the build and leaves the lake alone.
    before="$(sums "$lake")"
    rc=0; VARVE_MEMORY_LIMIT=1MB just build 2>"$tmp/build.err" || rc=$?
    if [ "$rc" -ne 1 ]; then echo "FAIL: a bound hit should exit the build 1, got $rc" >&2; tail -5 "$tmp/build.err" >&2; fail=1; fi
    if [ -e "$lake.new" ] || [ "$(sums "$lake")" != "$before" ]; then
      echo "FAIL: a bound hit left lake.new behind or changed the lake" >&2; fail=1
    fi

    # A lost session fails the build and leaves the lake alone; forget then passes.
    mv "$VARVE_MIRROR/claude-code/testproj/session-noise.jsonl" "$tmp/session-noise.jsonl"
    rc=0; just build 2>"$tmp/build.err" || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'check no_lost_sessions' "$tmp/build.err"; then
      echo "FAIL: a lost session should fail no_lost_sessions, got exit $rc" >&2; tail -5 "$tmp/build.err" >&2; fail=1
    fi
    if [ -e "$lake.new" ] || [ "$(sums "$lake")" != "$before" ]; then
      echo "FAIL: a failed check left lake.new behind or changed the lake" >&2; fail=1
    fi
    if ! just forget test-session-noise 2>"$tmp/forget.err"; then
      echo "FAIL: just forget did not clear the lost session" >&2; tail -5 "$tmp/forget.err" >&2; fail=1
    fi
    n="$(just sql -noheader -list -c "SELECT count(*) FROM sessions WHERE session_id = 'test-session-noise';")"
    if [ "$n" != "0" ]; then echo "FAIL: the forgotten session is still in the lake" >&2; fail=1; fi

    exit $fail
