-- varve pi adapter. Reads the mirrored pi JSONL session files and derives the
-- four normalized tables stg_sessions, stg_messages, stg_api_calls and
-- stg_tool_calls; the build copies them to the lake.
--
-- STATUS: correct by construction against the pi v3 session-format spec
-- (earendil-works/pi, packages/coding-agent/docs/session-format.md); so far it
-- has executed against a single-session real corpus only. Validate row counts
-- and reconcile inline against computed cost before trusting it at scale.
-- (RFC-0001 records this as a coverage limitation.)
--
-- Depends on sql/prelude.sql (run first): _attr_rules, _pricing, varve_harness(),
-- varve_campaign(). Variable set by the build:
--   mirror_dir : this runtime's mirror folder (no trailing slash)
--
-- Source shape (pi v3 spec):
--   * Path: <dir-encoded-cwd>/<timestamp>_<id>.jsonl.
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
-- Nested camelCase fields (usage.cacheRead, cost.total) are read with json_extract on
-- the message JSON, so struct-inference casing cannot silently miss them.

CREATE OR REPLACE TABLE _pi_raw AS
SELECT * FROM read_json(
  getvariable('mirror_dir') || '/**/*.jsonl',
  format              = 'newline_delimited',
  records             = true,
  ignore_errors       = true,
  filename            = true,
  maximum_object_size = 100000000,
  columns = {
    type:      'VARCHAR',
    id:        'VARCHAR',
    parentId:  'VARCHAR',
    timestamp: 'TIMESTAMP',
    version:   'VARCHAR',
    cwd:       'VARCHAR',
    message:   'JSON'
  }
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
CREATE OR REPLACE TABLE stg_sessions AS
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
  NULL::varchar                     AS cc_version,
  pi_version,
  NULL::varchar                     AS oc_version,
  NULL::varchar                     AS agent,
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
-- messages: one row per user/assistant/toolResult entry. is_sidechain is false:
-- pi has no sidechain flag; branching is the parent_id tree.
--
-- Entry content is a string or an array of blocks. The array rows are
-- materialized before the json[] cast, as in the Claude Code adapter. text is
-- the string or the joined text blocks; a toolResult entry carries no text, its
-- body is the tool_calls result_text. interrupted is NULL: pi records no
-- interrupt signal that a query reads.
CREATE OR REPLACE TABLE _pi_msg AS
SELECT message_id, session_id, parent_id, record_type, timestamp, date,
       json_extract_string(mj, '$.role')            AS role,
       json_extract(mj, '$.content')                AS cj,
       json_extract_string(mj, '$.toolCallId')      AS tool_use_id,
       json_extract_string(mj, '$.toolName')        AS tool_name,
       json_extract(mj, '$.isError')::boolean       AS is_error
FROM _pi_entries
WHERE json_extract_string(mj, '$.role') IN ('user','assistant','toolResult');

CREATE OR REPLACE TABLE _pi_arr_raw AS
SELECT * FROM _pi_msg WHERE json_type(cj) = 'ARRAY';

CREATE OR REPLACE TABLE _pi_msg_x AS
SELECT message_id, session_id, parent_id, record_type, timestamp, date, role,
       tool_use_id, tool_name, is_error,
       _join_blocks(list_transform(list_filter(blocks, lambda j: _block_type(j) = 'text'),
                                   lambda j: json_extract_string(j, '$.text'))) AS txt
FROM (SELECT *, cast(cj AS json[]) AS blocks FROM _pi_arr_raw)
UNION ALL
SELECT message_id, session_id, parent_id, record_type, timestamp, date, role,
       tool_use_id, tool_name, is_error,
       CASE WHEN json_type(cj) = 'VARCHAR' THEN json_extract_string(cj, '$') END
FROM _pi_msg WHERE json_type(cj) IS DISTINCT FROM 'ARRAY';

-- Arguments of each tool call, from the assistant entry's toolCall blocks.
CREATE OR REPLACE TABLE _pi_calls AS
SELECT session_id, blk ->> 'id' AS tool_use_id, min((blk -> 'arguments')::varchar) AS arguments
FROM (SELECT session_id, unnest(cast(cj AS json[])) AS blk
      FROM _pi_arr_raw WHERE role = 'assistant')
WHERE blk ->> 'type' = 'toolCall'
GROUP BY session_id, blk ->> 'id';
DROP TABLE _pi_arr_raw;

CREATE OR REPLACE TABLE stg_messages AS
SELECT
  message_id,
  session_id,
  role,
  parent_id,
  false                                    AS is_sidechain,
  timestamp,
  record_type,
  NULL::varchar                            AS api_message_id,
  CASE role WHEN 'toolResult' THEN 'tool_result'
            WHEN 'user' THEN 'operator'
            WHEN 'assistant' THEN 'model' END AS origin,
  CASE WHEN role <> 'toolResult' THEN txt END AS text,
  NULL::boolean                            AS interrupted,
  'pi'                                     AS runtime,
  date
FROM _pi_msg_x;

-- ---------------------------------------------------------------------------
-- api_calls: assistant entries. usage -> tokens; cost.total is pi's inline cost.
-- Cost policy (RFC-0001): prefer the runtime's inline cost.total when present;
-- else compute from tokens x pricing table. unpriced_model flags a model absent from the
-- pricing table. The inline-vs-computed reconciliation delta is a query-time concern
-- (queries/reconcile_pi_cost.sql), not a stored column.
CREATE OR REPLACE TABLE stg_api_calls AS
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
-- tool_calls: one row per toolResult entry (the documented, reliable source).
-- pi has no tool timing, so ended_at and duration_ms are NULL. outcome is error
-- when isError is set, else ok. arguments come from the assistant entry's
-- toolCall block with the same id, NULL when none is found.
CREATE OR REPLACE TABLE stg_tool_calls AS
SELECT
  t.session_id,
  t.message_id,
  t.tool_use_id,
  t.tool_name,
  t.timestamp                                               AS started_at,
  NULL::timestamp                                           AS ended_at,
  NULL::bigint                                              AS duration_ms,
  CASE WHEN t.is_error THEN 'error' ELSE 'ok' END           AS outcome,
  c.arguments,
  t.txt                                                     AS result_text,
  NULL::varchar                                             AS mcp_server,
  NULL::varchar                                             AS mcp_tool,
  t.message_id                                              AS result_message_id,
  'pi'                                                      AS runtime,
  t.date
FROM _pi_msg_x t
LEFT JOIN _pi_calls c ON c.session_id = t.session_id AND c.tool_use_id = t.tool_use_id
WHERE t.role = 'toolResult';
