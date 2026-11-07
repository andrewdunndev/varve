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
