-- varve shared adapter prelude (W2). Loaded once, before every runtime adapter,
-- so all three (claude_code / pi / opencode) resolve attribution and pricing the
-- same way. Extracted from the W1 Claude Code adapter when pi + opencode landed
-- (RFC-0001: attribution logic is shared, not replicated per adapter).
--
-- Variables (set by the justfile): repo_dir (to read the versioned CSV seeds);
-- attribution (path to the OPERATOR's rule CSV -- operator data, lives outside
-- the repo at a configured path per the public-instrument rule; the justfile
-- fails loudly when it is absent; format = adapters/attribution.example.csv).

-- Attribution rules (operator data, configured path). Pricing stays a repo seed.
CREATE OR REPLACE TABLE _attr_rules AS
SELECT * FROM read_csv(getvariable('attribution'),
  header = true, comment = '#', auto_detect = true);

CREATE OR REPLACE TABLE _pricing AS
SELECT * FROM read_csv(getvariable('repo_dir') || '/adapters/pricing.csv',
  header = true, comment = '#', auto_detect = true);

-- Attribution structural-token resolution (ADR-0005). Every adapter matches its
-- session cwd against _attr_rules (lowest-priority glob wins), then resolves the
-- {repo}/{worktree} tokens from the cwd via these macros -- identical logic for
-- all runtimes so the estate/harness/campaign columns mean the same thing.
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
