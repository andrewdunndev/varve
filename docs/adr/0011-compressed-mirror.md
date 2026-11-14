# ADR-0011: Retained mirror as Parquet line tables

- **Status:** accepted
- **Supersedes:** the plain-copy parts of ADR-0008 (`cp -p`, never-shorter on mirror file bytes, `build` reading the mirrored files and database in place)
- **Date:** 2026-11-13
- **Deciders:** maintainer. The operator chose raw Parquet over per-file zstd (measured: 3.5x to 4.2x against 4.2x to 4.4x, and the adapters read frames of files).

## Context

- varve keeps a highly compressed data lake, not a copy. The data home is 17G: mirror 15.7G (claude-code 14.9G in 22633 `*.jsonl`, opencode 0.85G database, pi 4K), lake 1.0G.
- The lake cannot rebuild itself, so the retained form keeps every source byte. APFS clones do not count: a clone stops sharing space when the source is deleted.
- The JSONL runtimes only append. Claude Code's cleanup deletes whole sessions at the source.
- Measured at nice 19, 2 threads, on a copy of 2308 real files (755MB), line table `(rel_path, line_no, line)`:

| Form | Size | Ratio | Wall |
|------|------|-------|------|
| per-file zstd 19 | 3.45x | | 118s |
| Parquet zstd 9 | 189.6MB | 4.15x | 4s |
| Parquet zstd 15 | 186.6MB | 4.21x | 42s |
| Parquet zstd 19 | 179.4MB | 4.38x | 59s |

- Sorting by `(rel_path, line_no)` moves size under 0.1%. Row groups of 5000 rows cost 0.7%. `rel_path` and `line_no` are 0.08% of the file. Nine large files (530MB, up to 122MB each) reach 5.0x at level 9.
- Base64 images are 16% to 21% of raw bytes and 31% to 43% of compressed bytes. Identical lines are 0.4% to 2.5%.
- A parquet table read through `read_blob` rebuilt 2308 of 2308 and 9 of 9 files with sha256 equal to the source.
- Parsing JSON from the `line` column gives the same row counts and fingerprints as `read_json` over files (29 sessions, 173795 messages, 50444 api calls, 59938 tool calls, cost 831.391435; and 9, 67210, 18589, 19013 on the large files), with one tool-block rule: see Decision.

## Decision

- A runtime without a `replace` set is retained as Parquet under `mirror/<runtime>/`, ZSTD:
  - `manifest.parquet`: one row per source file: `rel_path, bucket, bytes, lines, tail, sha256, src_size, src_mtime, status`. Its key-value metadata holds `gen`, the committed generation.
  - `lines/bucket=<b>/c-<gen>.parquet` and `d-<gen>-<n>.parquet`: rows `(rel_path, line_no, line)`. `line` is VARCHAR, one complete line without its newline. A file is the lines each followed by `\n`, then `tail`.
- `bucket` is the ISO week of the source mtime at first retention, with a `.k` shard when the week passes 512MB of source bytes. A file never changes bucket. About 30 buckets cover the corpus.
- `sha256` is over every retained byte. `bytes = sum(len(line)+1) + len(tail)`.
- **Sync.** One scan lists size and nanosecond mtime. A file equal to its manifest row is skipped without being opened. For a changed file, one pass hashes the whole source and checks that its first `bytes` bytes hash to the manifest `sha256`. Then the lines from the last complete-line boundary (the old `tail` is re-read) become a delta; the new `tail` is the bytes after the last newline.
  - A prefix mismatch (rewritten or shorter source) keeps the retained copy and sets `status = diverged`. The manifest keeps the old `src_size` and `src_mtime`, so the file is read and named again on every sync, and `just check` fails while any file is diverged (`checks/diverged.sql`). The new source bytes are not retained.
  - A partial last line is never a line. It lives in `tail` until the next sync completes it.
  - A file that is not UTF-8 is left unretained, counted, and retried next sync.
  - A file that changed between the two passes is `unstable` and retried next sync.
  - A file over `VARVE_MAX_FILE` (160MB) is not retained, whether new or grown past the cap, and is named; the sync exits 1. The pass holds the file in memory several times over.
- **Commit.** Sync works in batches of at most 256MB of source bytes. A batch writes its deltas under `lines.tmp/`, reads them back and checks per file the row count and byte count, renames the delta files into place, then renames the new manifest with `gen + 1`. The manifest is the only commit. A file in `lines/` whose gen is above the manifest's, or that a newer `c-` file replaced, is garbage; every sync, build and forget sweeps it first. A crash at any point leaves the previous manifest and its files valid. The sweep deletes nothing, and exits 2, when the manifest has no `gen` or when `lines/` holds files and there is no manifest.
- **Compaction.** When a bucket holds 8 deltas, or on `--compact`, sync rewrites that bucket as one `c-<gen>.parquet` sorted by `(rel_path, line_no)` at level 19, from the old `c-` and its deltas. Before the manifest rename it checks that the row count and `sum(hash(rel_path, line_no, line))` equal the inputs and that every file's line count equals the manifest. Memory is the sort of one bucket.
- **Levels.** Deltas are level 9 (a 755MB sync takes 14s against 110s at level 19; 5% larger); compacted buckets level 19; row groups 20000 rows or 64MB.
- **Exact check.** `bin/sync --verify` rebuilds each file from its lines in batches of 256MB and compares its sha256 with the manifest. `bin/pack --verify` also compares it with the plain file.
- **Build.** The claude-code and pi adapters read `lines/*/*.parquet` and parse JSON from `line` with `json_transform` and `json_valid`; `rel_path` is the old `filename`. Tool blocks come from their own narrow parse of only the lines that contain `"tool_use"` or `"tool_result"`; parsing every line wide ran out of the 3GB limit on image payloads.
- **forget.** A session's files are found in the manifest by `contains(rel_path, id)`. Each affected bucket is compacted without them, verified as above, and committed with their rows gone. Other buckets are untouched.
- **opencode.** The replace set stays a verified `.db.zst` frame pair unpacked per build (zstd 19 gives 15.5x, 848MB to 55MB); a Parquet form of rows would add a lossless-round-trip proof for no saving.
- `sync` opens the engine only through `bin/duck`, so it shares the lock and the caps of ADR-0010; it and `build` never overlap.
- The plain mirror goes by `bin/pack`, a one-shot: it retains the plain `*.jsonl` of each such runtime in place with the sync code, writes `.zst` beside the replace set, and `--verify` checks every file by sha256 against the plain file and prints counts. `bin/pack --delete-plain` runs the same verification and deletes each plain file that passed: a runtime's line files when all of them match their lines, a replace-set file when its frame decompresses to the same bytes. Frames and lines are never deleted. The operator runs no other delete.

**Rejected**
- Per-file zstd 19 (ruled earlier): 3.45x to 4.2x, and adapters stay on files. The operator chose the table.
- One Parquet file per source file: tens of thousands of tiny files. One table rewritten per sync: 1.7GB per week rewritten nightly.
- `read_csv` for lines: `max_line_size` allocates gigabytes. Dedup of identical lines: 0.4% to 2.5%.
- Hash joins between `todo` and `read_blob`: DuckDB buffered the blob side, 4.2GB peak against 3.0GB with the parameters in maps.

## Consequences

**Positive**
- Mirror 15.7G to about 3.0G to 3.5G; data home 17G to about 4.3G to 4.7G (claude-code 3.5G, opencode 0.06G, lake 1.0G), under 28% of today. The migration sample (314.6MB from 20 projects, including the 122MB and 75MB files, built by `bin/pack`) kept 73.25MB, 4.29x; the 2308-file sample above kept 4.4x. The ratio is sample-specific: an earlier 310MB sample of 1181 files kept 5.2x.
- A session deleted at its source stays queryable in SQL straight from the retained lines; the lake rebuilds from them alone.
- Routine sync: a no-change run over 1181 files takes 0.13s and starts no engine; 100 grown files (26MB) take 1.5s.

**Negative**
- `sync` needs the engine; ADR-0010's "sync never opens DuckDB" is amended.
- First conversion about 45 min at nice 19 on 2 threads (the 314MB sample, 1.42GB peak resident, extrapolated by bytes), verify about 2.5 min (3s for the sample), opencode about 1 min.
- Build is slower and larger than over plain files: 19.7s under load and 1.35GB peak resident against 7.6s and 1.07GB for a build over the plain files on the same sample; 4.6s against 1.5s on the large files. Full corpus about 2.5 to 3.5 min against 2.0.
- Peak resident is about 1.4GB in sync at 2 threads, measured over a sample holding the 122MB and 75MB files. A file whose pass would not fit is not retained, named, and fails the sync.
- A source rewritten in place stops being followed; the retained copy is the old bytes.
- A data-home adapter that reads files breaks once.

## References

- Supersedes parts of ADR-0008. Amends ADR-0010 (`sync` runs through `bin/duck`). ADR-0003 and ADR-0009 hold.
