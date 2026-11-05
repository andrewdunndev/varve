-- varve pi adapter (W2). Reads pi's append-only JSONL session files and derives
-- the four normalized per-runtime staging tables (_pi_sessions, _pi_messages,
-- _pi_api_calls, _pi_tool_calls) plus a file->session->date map (_pi_files).
-- sql/stage.sql unions these into the shared stg_*.
--
-- STATUS: correct-by-construction against the pi v3 session-format spec
-- (earendil-works/pi, packages/coding-agent/docs/session-format.md). There is NO
-- pi install on the build machine, so it only runs where a pi corpus exists
-- (the justfile skips it cleanly when no pi JSONL is present); so far it has
-- executed against a single-session real corpus only. Validate row counts +
-- reconcile inline vs computed cost before trusting it at scale.
-- (RFC-0001 records this as a coverage limitation.)
--
-- Depends on sql/prelude.sql (run first): _attr_rules, _pricing, varve_harness(),
-- varve_campaign(). Variables (set by the justfile):
--   pi_source : recursive glob of pi JSONL (~/.pi/agent/sessions/**/*.jsonl)
--   repo_dir  : this repo root.
--
-- Source shape (pi v3 spec):
--   * Path: ~/.pi/agent/sessions/<dir-encoded-cwd>/<timestamp>_<id>.jsonl.
--   * Line 1 header: {"type":"session","version":3,"id":<uuid>,
--     "timestamp":<ISO>,"cwd":<path>}. The session id + cwd live ONLY here;
--     entries carry no sessionId, so entries link to their session by FILENAME.
--   * Entries: {"type":..,"id":<8hex>,"parentId":<null|8hex>,"timestamp":<ISO>,
--     "message":{...}} -- tree-structured via parentId (branching, not linear).
--   * message.role in {user, assistant, toolResult}. AssistantMessage carries
--     per-API-call usage {input, output, cacheRead, cacheWrite, totalTokens} AND
--     inline-computed cost {input, output, cacheRead, cacheWrite, total}, plus
--     model, provider, api, stopReason. ToolResultMessage carries toolCallId,
--     toolName, isError.
--
-- COVERAGE HOLE (upstream gap, ADR-0006 / RFC-0001): pi subagents spawn
-- `pi --no-session` children that write NO transcript; the parent records only a
-- rolled-up usage blob. Child-session linkage is therefore empty for pi and those
-- child API calls are not individually observable. We do NOT fabricate child
-- rows -- the subagent's cost folds into the parent's rolled-up usage if pi
-- writes one, else it is simply absent.
--
-- Nested camelCase fields (usage.cacheRead, cost.total) are read via CAST(message
-- AS JSON) + json_extract so struct-inference casing cannot silently miss them.

CREATE OR REPLACE TABLE _pi_raw AS
SELECT * FROM read_json(
  getvariable('pi_source'),
  format              = 'newline_delimited',
  union_by_name       = true,
  ignore_errors       = true,
  filename            = true,
  maximum_object_size = getvariable('json_max_object'),
  -- DuckDB 2.x otherwise collapses a many-keyed corpus into one json MAP column
  map_inference_threshold = -1
);

-- Header line per file: the only place carrying session id + cwd + version.
CREATE OR REPLACE TABLE _pi_headers AS
SELECT
  filename                       AS path,
  id::varchar                    AS session_id,
  cwd                            AS cwd,
  timestamp::timestamp           AS started_at,
  version::varchar               AS pi_version
FROM _pi_raw
WHERE type = 'session' AND id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- sessions: one row per header. Attribution via the shared rules/macros on cwd.
-- parent_session_id is NULL (pi branches WITHIN a session via message parentId;
-- there is no session->session parent chain, and --no-session children write no
-- transcript -- see coverage hole above).
CREATE OR REPLACE TABLE _pi_sessions AS
WITH matched AS (
  SELECT h.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM _pi_headers h
  JOIN _attr_rules r
    ON coalesce(h.cwd,'') LIKE replace(r.cwd_glob, '*', '%')
  QUALIFY row_number() OVER (PARTITION BY h.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'pi'                              AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)   AS harness,
  estate,
  varve_campaign(cwd, campaign_tok) AS campaign,
  started_at,
  NULL::varchar                     AS parent_session_id,
  pi_version,
  strftime(started_at, '%Y-%m-%d')  AS date
FROM matched;

-- Entries joined to their session by filename (entries carry no sessionId).
CREATE OR REPLACE TABLE _pi_entries AS
SELECT
  e.id::varchar                    AS message_id,
  h.session_id                     AS session_id,
  e.parentId::varchar              AS parent_id,
  e.type                           AS record_type,
  e.timestamp::timestamp           AS timestamp,
  CAST(e.message AS JSON)          AS mj,
  h.date                           AS date
FROM _pi_raw e
JOIN (SELECT path, session_id, strftime(started_at,'%Y-%m-%d') AS date FROM _pi_headers) h
  ON e.filename = h.path
WHERE e.type IS DISTINCT FROM 'session' AND e.id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- messages: one row per user/assistant/toolResult entry. Content inlined
-- (RFC-0001). is_sidechain false -- pi has no sidechain flag; branching is the
-- parent_id tree.
CREATE OR REPLACE TABLE _pi_messages AS
SELECT
  message_id,
  session_id,
  json_extract_string(mj, '$.role')       AS role,
  parent_id,
  false                                    AS is_sidechain,
  timestamp,
  record_type,
  NULL::varchar                            AS api_message_id,
  json_extract_string(mj, '$.content')     AS content,
  'pi'                                     AS runtime,
  date
FROM _pi_entries
WHERE json_extract_string(mj, '$.role') IN ('user','assistant','toolResult');

-- ---------------------------------------------------------------------------
-- api_calls: assistant entries. usage -> tokens; cost.total is pi's inline cost.
-- Cost policy (RFC-0001): prefer the runtime's inline cost.total when present;
-- else compute from tokens x seed. unpriced_model flags a model absent from the
-- seed. The inline-vs-computed reconciliation delta is a query-time concern
-- (queries/reconcile_pi_cost.sql), not a stored column.
CREATE OR REPLACE TABLE _pi_api_calls AS
WITH asst AS (
  SELECT
    session_id,
    message_id,
    timestamp,
    json_extract_string(mj, '$.model')                          AS model,
    json_extract_string(mj, '$.provider')                       AS provider,
    coalesce(json_extract(mj, '$.usage.input')::bigint,0)       AS input,
    coalesce(json_extract(mj, '$.usage.output')::bigint,0)      AS output,
    coalesce(json_extract(mj, '$.usage.cacheRead')::bigint,0)   AS cache_read,
    coalesce(json_extract(mj, '$.usage.cacheWrite')::bigint,0)  AS cache_write,
    try_cast(json_extract(mj, '$.cost.total') AS double)        AS inline_cost,
    date
  FROM _pi_entries
  WHERE json_extract_string(mj, '$.role') = 'assistant'
)
SELECT
  a.session_id,
  a.message_id,
  NULL::varchar                              AS api_message_id,
  NULL::varchar                              AS request_id,
  a.timestamp,
  a.model,
  a.provider,
  a.input, a.output, a.cache_read, a.cache_write,
  coalesce(
    CASE WHEN a.inline_cost IS NOT NULL AND a.inline_cost > 0 THEN a.inline_cost END,
    round(
        a.input       * coalesce(p.input_cost,0)
      + a.output      * coalesce(p.output_cost,0)
      + a.cache_read  * coalesce(p.cache_read_cost,0)
      + a.cache_write * coalesce(p.cache_creation_cost,0), 6),
    0)                                       AS cost_usd,
  (p.model IS NULL)                          AS unpriced_model,
  'pi'                                       AS runtime,
  a.date
FROM asst a
LEFT JOIN _pricing p ON a.model = p.model;

-- ---------------------------------------------------------------------------
-- tool_calls: derived from toolResult entries (the documented, reliable source;
-- the assistant content-array block shape is not spec'd). pi has no tool timing,
-- so ended_at/duration_ms are NULL (like Claude Code); decision carries the
-- isError status when present.
CREATE OR REPLACE TABLE _pi_tool_calls AS
SELECT
  session_id,
  message_id,
  json_extract_string(mj, '$.toolCallId')                   AS tool_use_id,
  json_extract_string(mj, '$.toolName')                     AS tool_name,
  timestamp                                                 AS started_at,
  NULL::timestamp                                           AS ended_at,
  NULL::bigint                                              AS duration_ms,
  CASE WHEN json_extract(mj, '$.isError')::boolean THEN 'error' END AS decision,
  'pi'                                                      AS runtime,
  date
FROM _pi_entries
WHERE json_extract_string(mj, '$.role') = 'toolResult';

-- ---------------------------------------------------------------------------
-- file -> session -> date map. One file per session; a grown (appended) file
-- changes size+mtime -> its date partition rebuilds from full content -> live
-- pi-session appends counted exactly once (same model as Claude Code).
CREATE OR REPLACE TABLE _pi_files AS
SELECT DISTINCT path, session_id, strftime(started_at,'%Y-%m-%d') AS date
FROM _pi_headers;
