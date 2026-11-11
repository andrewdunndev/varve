# ADR-0011: Compressed mirror

- **Status:** accepted
- **Supersedes:** the plain-copy parts of ADR-0008 (`cp -p`, never-shorter on mirror file bytes, `build` reading the mirrored database in place)
- **Date:** 2026-11-11
- **Deciders:** maintainer. The per-file zstd 19 choice (about 5.2G, over the 3G target) is recorded as ruled; the operator's explicit acceptance of 5.2G is unconfirmed here.

## Context

- The data home is 17G: mirror 15.7G (claude-code 14.9G in 22633 `*.jsonl`, opencode 0.85G database, pi 4K), lake 1.0G. The mirror is a plain copy.
- Ruling: a highly compressed lake, not a copy. APFS clones do not count: a clone stops sharing space when Claude Code's cleanup deletes the source.
- The lake cannot rebuild itself (the claude-code adapter no longer materializes content), so the retained form keeps every source byte.
- Measured on real mirror files, nice 19, 2 threads. Sample 1: 1135 files, 1.065G, every 20th file by size plus the 3 largest. Sample 2: 2308 files, 0.787G, 8 whole project directories. Ratio is raw / compressed.

| Form | Sample 1 | Sample 2 | Wall, sample 2 |
|------|----------|----------|----------------|
| per-file zstd 3 | 3.50 | 3.19 | 16s |
| per-file zstd 9 | 3.76 | 3.35 | 20s |
| per-file zstd 19 | 3.54 (269MB subset) | 3.45 | 118s |
| per-file zstd 19 `--long=27` | 3.64 (subset) | 3.45 | 127s |
| line table in Parquet, zstd 9, 100k-row groups | 4.13 | 4.15 | 5s |
| line table in Parquet, zstd 19 | 4.28 | 4.37 | 98s |
| one solid stream, zstd 9 `--long=27` | n/a | 4.62 | n/a |
| one solid stream, zstd 19 `--long=27` | n/a | 4.86 | n/a |
| per-file gzip 9 | n/a | 2.74 | 20s |

- Sample 1 stratified to the 14.9G population (<10K, 10K-1M, 1M-20M, >20M by size): per-file zstd 9 lands at 4.3G, zstd 19 at about 4.2G. Parquet saves 9% to 21% against per-file, the solid stream 29%.
- Base64 image blocks are 21% of raw bytes in sample 1 and 16% in sample 2, and 43% and 31% of compressed bytes. Identical lines are 2.5% and 0.4% of bytes. Nothing lossless takes the claude-code mirror under about 3G.
- The opencode database is 848MB. Its first 400MB compresses 9.8x at zstd 9 and 10.9x at zstd 19, so the file is about 80MB.
- DuckDB 1.5.6 reads `*.jsonl.zst` through `read_json` and the adapter's own call (schema, `filename`, `maximum_object_size`), including a file of two concatenated frames. A build over sample 1 gave identical row counts and an identical cost hash from `.jsonl` and `.jsonl.zst`: 8.5s and 9.7s. It cannot open a compressed SQLite file.
- `zstd -lv` reads a frame's decompressed size from its header, without decoding, when the frame was made from a file path (not stdin).
- A Parquet line table (path, line number, text) rebuilt 3443 files whose md5 equals the source's.

## Decision

- The mirror holds each included file as `<rel>.zst`: one zstd frame, level 19, `-T2`, no long window (0 to 3% gain). The frame is made from the source file path, so its header carries the size.
- The `.zst` carries the source's nanosecond mtime (`touch -r`). Equal mtime means unchanged: sync spawns no process for it.
- A changed source is compared by size with the retained file's decompressed size (`zstd -lv`). A shorter source is skipped and counted: never-shorter now binds decompressed bytes. Otherwise sync recompresses the whole source into a temp name, retries up to 3 times if the source's size or mtime moved while reading, runs `zstd -t`, requires the decompressed size to equal the size read, then renames. Sync never appends a frame: that needs a proof that the retained bytes are a prefix of the source, and a recompress of the largest file costs about 15s.
- A source deleted after sync leaves its `.zst`. Nothing removes a mirror file except `just forget`.
- The replace set is staged compressed as a unit, under the stat check of ADR-0008, and renamed together. Names are `<file>.zst`.
- Adapters read `**/*.jsonl.zst`; the repo's claude-code and pi adapters change their glob and path regexes. A data-home adapter that globs `*.jsonl` reads nothing and must change the same way.
- For a runtime with a replace set, `build` decompresses the set into `state/unpack.<pid>/<runtime>/`, runs the adapter with that as `mirror_dir`, and removes it when the runtime finishes. The opencode adapter does not change. Stale unpack directories of dead pids go at the next build, as run directories do. The unpack counts against `VARVE_MAX_SPILL` and a 5G disk floor: before unpacking, `build` sums the frame headers' decompressed sizes, and over either bound it keeps that runtime's published partitions and says so on stderr.
- The lake is written with `COMPRESSION_LEVEL 19`. On sample 2 that cut it 12% (62.4MB to 55.0MB).
- `zstd` is a system dependency beside `sqlite3`, called from `PATH`; the scripts exit 2 with a one-line message when it is missing.
- The plain mirror goes by `bin/pack`, a one-shot: it writes `NAME.zst` beside each plain file and never touches the plain file; `bin/pack --verify` checks each pair by decompress-and-hash. `pack` skips a frame only when it passes `zstd -t` and carries the plain file's mtime, so a plain file that grew is recompressed. `--verify` lists only mismatches and prints a count on success. Only after `--verify` exits 0 does the operator remove plain files, and only those that have a frame: `find mirror -name '*.jsonl' | while read -r f; do [ -f "$f.zst" ] && rm "$f"; done`. Later syncs find equal mtimes and copy nothing. Delete `bin/pack` once the migration is done.

**Rejected**
- gzip: 2.74x against 3.45x, 26% larger, but no new dependency. zstd gives 1.2G less on the full mirror.
- Parquet line table or one solid stream: 9% to 29% smaller (measured floor: claude-code about 3G, data home about 4G; the operator ruled per-file zstd 19 at about 5.2G), but adapters would read a table instead of files, an appended session needs part files and compaction, and ADR-0008's files primitive goes.
- Frame append: see above.
- zstd dictionaries: DuckDB's reader cannot use them.
- Decompress the whole mirror to scratch each build: 15G written per build, against streaming reads at +14% build time.

## Consequences

**Positive**
- Mirror 15.7G to about 4.3G; data home 17G to about 5.2G (claude-code 4.2G, opencode 0.08G, lake 0.88G), 31% of today.
- Adapters stay files and SQL. Sync still never opens DuckDB.
- Routine sync costs one stat pair per file. A changed file costs about 8.5MB/s of CPU at nice 19.
- Proofs: a session deleted at source stays queryable from its `.zst`; the lake rebuilds from the mirror alone, with no source and no plain file.

**Negative**
- A target of under 3G is not met: lossless retention floors near 5G. Base64 images are 31% to 43% of the compressed mirror. Dropping them breaks ADR-0003 and still leaves about 3.5G to 4G; it needs the operator.
- First conversion: about 26 to 37 min of CPU at zstd 19 on one process, about 15 to 19 min on two; opencode adds 40s.
- A corrupt frame fails its runtime's build, which keeps its published partitions. Sync tests each frame before the rename.
- Rebuild of the full corpus: about 2.0 min plain, 2.3 min from `.zst` (linear from sample 1), plus 0.85G written once for opencode.
- A rewound source that later outgrows the retained length overwrites it, as in ADR-0008.
- Data-home adapters break once.

**Neutral**
- Level 19 gains 3% over level 9 for 5x the time; one constant in `bin/sync`.
- A solid stream stays the next lever if the operator wants about 1G more.

## References

- Supersedes parts of ADR-0008. ADR-0003, ADR-0009 and ADR-0010 hold.
