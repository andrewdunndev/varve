-- Shared adapter prelude, loaded before each runtime adapter so all three
-- resolve attribution and pricing the same way.
--
-- attribution and pricing are the data home's attribution.toml and
-- pricing.toml, exposed as views by bin/duck. forgotten is the data home's
-- forgotten.toml when it exists, else empty.

CREATE OR REPLACE TABLE _attr_rules AS SELECT * FROM attribution;
CREATE OR REPLACE TABLE _pricing AS SELECT * FROM pricing;

CREATE VIEW IF NOT EXISTS forgotten AS SELECT NULL::VARCHAR AS session_id WHERE false;

-- Attribution structural-token resolution (ADR-0005). Every adapter matches its
-- session cwd against _attr_rules (lowest-priority glob wins), then resolves the
-- {repo}/{worktree} tokens from the cwd via these macros.
--   {repo}     -> repo dir after gitlab.com/<ns>/ or github.com/<ns>/
--   {worktree} -> segment after /.claude/worktrees/, else NULL; empty tok -> NULL
CREATE OR REPLACE MACRO varve_harness(cwd, tok) AS
  CASE WHEN tok = '{repo}'
       THEN nullif(regexp_extract(cwd, '/(?:gitlab\.com|github\.com)/[^/]+/([^/]+)', 1), '')
       ELSE tok END;

CREATE OR REPLACE MACRO varve_campaign(cwd, tok) AS
  CASE WHEN tok = '{worktree}'
       THEN nullif(regexp_extract(cwd, '/\.claude/worktrees/([^/]+)', 1), '')
       WHEN tok IS NULL OR tok = '' THEN NULL
       ELSE tok END;

-- Block-array text helpers shared by the adapters. _join_blocks has string_agg
-- semantics over a list: NULL elements are skipped, NULL when none remain. The
-- separator is the two characters backslash and n, not a newline; changing it
-- moves every token set built from joined text.
CREATE OR REPLACE MACRO _join_blocks(l) AS
  CASE WHEN len(list_filter(l, lambda x: x IS NOT NULL)) > 0 THEN array_to_string(l, '\n') END;
CREATE OR REPLACE MACRO _block_type(j) AS json_extract_string(j, '$.type');
