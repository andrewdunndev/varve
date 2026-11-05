-- varve Claude Code adapter (W1; W2 renamed staging stg_* -> _cc_* and moved the
-- shared seeds/macros to sql/prelude.sql when pi + opencode landed). Near-pure
-- DuckDB SQL, per ADR-0002. Reads raw Claude Code JSONL in place and derives the
-- four normalized per-runtime staging tables (_cc_sessions, _cc_messages,
-- _cc_api_calls, _cc_tool_calls) plus a file->session->date map (_cc_files) used
-- for incremental delta detection. sql/stage.sql unions the per-runtime staging
-- into the shared stg_* the pipeline COPYs to the lake.
--
-- Depends on sql/prelude.sql (run first): _attr_rules, _pricing, varve_harness(),
-- varve_campaign(). Variables (set by the justfile via `-c "SET VARIABLE ..."`):
--   cc_source : glob of source JSONL (recursive; MUST include subagent files)
--   repo_dir  : this repo root (to read the versioned CSV seeds)
--
-- Source shape (validated against the live corpus 2026-07-06, CC v2.1.x):
--   * ~/.claude/projects/<dashed-cwd>/<session_id>.jsonl  = main session
--   * .../<session_id>/subagents/agent-*.jsonl            = subagent (sidechain)
--     traffic; these carry the SAME sessionId as the parent, isSidechain=true.
--     The glob therefore MUST recurse (projects/**/*.jsonl) or subagent api
--     calls are silently lost.
--   * message.usage = {input_tokens, output_tokens, cache_read_input_tokens,
--     cache_creation_input_tokens} -- exactly the ccusage UsageEntry grain.
--   * costUSD is ABSENT from every record in this corpus -> cost is computed
--     from tokens x pricing.csv (LiteLLM rates), never read from the record.
--   * Streaming writes multiple lines sharing (message.id, requestId) with
--     identical input/cache but GROWING output_tokens; the final line holds the
--     complete usage. Dedup keeps MAX(output_tokens) per (message.id,requestId).
--   * model '<synthetic>' rows (zero tokens) are excluded, matching ccusage.

-- ---------------------------------------------------------------------------
-- Raw read. ignore_errors=true tolerates schema drift across CC versions
-- (2.1.114 .. 2.1.201 seen); union_by_name=true unions column presence.
CREATE OR REPLACE TABLE _cc_raw AS
SELECT * FROM read_json(
  getvariable('cc_source'),
  format             = 'newline_delimited',
  union_by_name      = true,
  ignore_errors      = true,
  filename           = true,
  maximum_object_size = getvariable('json_max_object'),
  -- DuckDB 2.x otherwise collapses a many-keyed corpus into one json MAP column
  map_inference_threshold = -1
);

-- ---------------------------------------------------------------------------
-- sessions: one row per sessionId (subagent files fold into their parent, so a
-- session spans the main file + its subagents). parent_session_id is NULL for
-- Claude Code -- CC has no session->session parent chain in these records; the
-- subagent linkage is carried at message grain via is_sidechain, not here.
CREATE OR REPLACE TABLE _cc_sessions AS
WITH base AS (
  SELECT sessionId::varchar          AS session_id,
         any_value(cwd)              AS cwd,
         min(timestamp)              AS started_at,
         any_value(version)          AS cc_version
  FROM _cc_raw
  WHERE sessionId IS NOT NULL
  GROUP BY sessionId
  -- Drop empty metadata-only session stubs: no timestamped activity means no
  -- messages/api_calls/tool_calls and no partition date. NULL cwd alone is kept
  -- (routed to the unknown estate below); only zero-activity stubs are excluded.
  HAVING min(timestamp) IS NOT NULL
),
matched AS (  -- first (lowest-priority) attribution rule whose glob matches cwd.
              -- coalesce so a NULL cwd still matches the '*' fallback (unknown).
  SELECT b.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM base b
  JOIN _attr_rules r
    ON coalesce(b.cwd,'') LIKE replace(r.cwd_glob, '*', '%')
  QUALIFY row_number() OVER (PARTITION BY b.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'claude-code'                                                    AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)                                  AS harness,
  estate,
  varve_campaign(cwd, campaign_tok)                                AS campaign,
  started_at,
  NULL::varchar                                                    AS parent_session_id,
  cc_version,
  strftime(started_at, '%Y-%m-%d')                                 AS date
FROM matched;

-- ---------------------------------------------------------------------------
-- messages: one row per user/assistant line. message_id = line uuid (unique per
-- event); api_message_id = provider message.id (msg_...), nullable. Content is
-- stored INLINE (RFC-0001 decision: lake is local-only per ADR-0004; inline
-- content enables W7 fts/vss). Other record types (system/mode/snapshot/...)
-- are not messages and are skipped -- the raw JSONL remains the source of truth.
CREATE OR REPLACE TABLE _cc_messages AS
SELECT
  r.uuid::varchar               AS message_id,
  r.sessionId::varchar          AS session_id,
  r.message.role                AS role,
  r.parentUuid::varchar         AS parent_id,
  coalesce(r.isSidechain,false) AS is_sidechain,
  r.timestamp                   AS timestamp,
  r.type                        AS record_type,
  r.message.id                  AS api_message_id,
  r.message.content::varchar    AS content,
  'claude-code'                 AS runtime,
  ss.date                       AS date
FROM _cc_raw r
JOIN _cc_sessions ss ON r.sessionId::varchar = ss.session_id
WHERE r.type IN ('user','assistant') AND r.uuid IS NOT NULL;

-- ---------------------------------------------------------------------------
-- api_calls: the ccusage UsageEntry spine. Dedup per (message.id, requestId)
-- taking MAX(output_tokens) (streaming final); input/cache are constant in a
-- group so MAX == the value. cost_usd computed from pricing.csv.
CREATE OR REPLACE TABLE _cc_api_calls AS
WITH asst AS (
  SELECT
    r.sessionId::varchar                        AS session_id,
    r.uuid::varchar                             AS line_uuid,
    r.message.id                                AS api_message_id,
    coalesce(r.requestId,'')                    AS request_id,
    r.timestamp                                 AS ts,
    r.message.model                             AS model,
    r.message.usage.input_tokens                AS inp,
    r.message.usage.output_tokens               AS outp,
    r.message.usage.cache_read_input_tokens     AS cr,
    r.message.usage.cache_creation_input_tokens AS cw
  FROM _cc_raw r
  WHERE r.type = 'assistant'
    AND r.message.id IS NOT NULL
    AND r.message.model IS DISTINCT FROM '<synthetic>'
),
dedup AS (
  SELECT
    api_message_id,
    nullif(request_id,'')          AS request_id,
    any_value(session_id)          AS session_id,
    any_value(model)               AS model,
    max_by(line_uuid, outp)        AS message_id,   -- representative line
    max_by(ts, outp)               AS timestamp,
    max(inp)                       AS input,
    max(outp)                      AS output,
    max(cr)                        AS cache_read,
    max(cw)                        AS cache_write
  FROM asst
  GROUP BY api_message_id, nullif(request_id,'')
)
SELECT
  d.session_id,
  d.message_id,
  d.api_message_id,
  d.request_id,
  d.timestamp,
  d.model,
  'anthropic'  AS provider,
  d.input, d.output, d.cache_read, d.cache_write,
  round(
    d.input      * coalesce(p.input_cost,0)
  + d.output     * coalesce(p.output_cost,0)
  + d.cache_read * coalesce(p.cache_read_cost,0)
  + d.cache_write* coalesce(p.cache_creation_cost,0), 6)          AS cost_usd,
  (p.model IS NULL)                                               AS unpriced_model,
  'claude-code' AS runtime,
  ss.date       AS date
FROM dedup d
LEFT JOIN _pricing p  ON d.model = p.model
JOIN _cc_sessions ss  ON d.session_id = ss.session_id;

-- ---------------------------------------------------------------------------
-- tool_calls: one row per assistant tool_use block. duration_ms / ended_at /
-- decision are NULL for Claude Code (only opencode records tool timing; ADR-0006).
--
-- message.content is an array of blocks for tool-bearing turns but a bare string
-- for plain-text messages. Casting the raw content to json[] and guarding with a
-- CASE is unsafe: the planner hoists the cast above the type filter and errors on
-- string content. So first MATERIALIZE only the array-content assistant rows,
-- which pins the cast to rows already known to be arrays.
CREATE OR REPLACE TABLE _cc_asst_blocks AS
SELECT sessionId::varchar AS session_id, uuid::varchar AS message_id,
       timestamp, message.content::json AS content_json
FROM _cc_raw
WHERE type = 'assistant' AND json_type(message.content::json) = 'ARRAY';

CREATE OR REPLACE TABLE _cc_tool_calls AS
SELECT
  b.session_id,
  b.message_id,
  blk ->> 'id'    AS tool_use_id,
  blk ->> 'name'  AS tool_name,
  b.timestamp     AS started_at,
  NULL::timestamp AS ended_at,
  NULL::bigint    AS duration_ms,
  NULL::varchar   AS decision,
  'claude-code'   AS runtime,
  ss.date         AS date
FROM _cc_asst_blocks b
JOIN _cc_sessions ss ON b.session_id = ss.session_id,
LATERAL (SELECT unnest(cast(b.content_json AS json[])) AS blk)
WHERE blk ->> 'type' = 'tool_use';

-- ---------------------------------------------------------------------------
-- file -> session -> date map for incremental delta detection. A change to any
-- file (main or subagent) marks its session's date partition for rewrite.
CREATE OR REPLACE TABLE _cc_files AS
SELECT DISTINCT r.filename AS path, r.sessionId::varchar AS session_id, ss.date
FROM _cc_raw r
JOIN _cc_sessions ss ON r.sessionId::varchar = ss.session_id
WHERE r.filename IS NOT NULL;
