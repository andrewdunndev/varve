-- varve Claude Code adapter. Near-pure SQL, per ADR-0002. Reads the mirrored
-- Claude Code JSONL and derives the four normalized tables stg_sessions,
-- stg_messages, stg_api_calls and stg_tool_calls; the build copies them to the
-- lake.
--
-- Depends on sql/prelude.sql (run first): _attr_rules, _pricing, varve_harness(),
-- varve_campaign(). Variable set by the build:
--   mirror_dir : this runtime's mirror folder (no trailing slash)
--
-- Source shape (Claude Code v2.1.x):
--   * ~/.claude/projects/<dashed-cwd>/<session_id>.jsonl  = main session
--   * .../<session_id>/subagents/agent-*.jsonl            = subagent (sidechain)
--     traffic; these carry the SAME sessionId as the parent, isSidechain=true.
--     The glob therefore MUST recurse (projects/**/*.jsonl) or subagent api
--     calls are silently lost.
--   * message.usage = {input_tokens, output_tokens, cache_read_input_tokens,
--     cache_creation_input_tokens} -- exactly the ccusage UsageEntry grain.
--   * costUSD is ABSENT from every record in this corpus -> cost is computed
--     from tokens x pricing.toml (LiteLLM rates), never read from the record.
--   * Streaming writes multiple lines sharing (message.id, requestId) with
--     identical input/cache but GROWING output_tokens; the final line holds the
--     complete usage. Dedup keeps MAX(output_tokens) per (message.id,requestId).
--   * model '<synthetic>' rows (zero tokens) are excluded, matching ccusage.

-- ---------------------------------------------------------------------------
-- Raw read with an explicit schema: inference over the whole corpus collapses
-- to a single MAP column once rare top-level keys accumulate. Only main session
-- files (<project>/<id>.jsonl) and subagent transcripts are read; other JSONL
-- (workflow journals, tool output) is skipped. Values that do not fit the
-- schema read as NULL (ignore_errors).
CREATE OR REPLACE VIEW _cc_raw AS
SELECT * FROM read_json(
  getvariable('mirror_dir') || '/**/*.jsonl',
  format              = 'newline_delimited',
  records             = true,
  ignore_errors       = true,
  filename            = true,
  maximum_object_size = 100000000,
  columns = {
    sessionId:   'VARCHAR',
    cwd:         'VARCHAR',
    timestamp:   'TIMESTAMP',
    version:     'VARCHAR',
    uuid:        'VARCHAR',
    parentUuid:  'VARCHAR',
    isSidechain: 'BOOLEAN',
    isMeta:      'BOOLEAN',
    type:        'VARCHAR',
    requestId:   'VARCHAR',
    message:     'STRUCT(role VARCHAR, id VARCHAR, model VARCHAR, content JSON,
                  usage STRUCT(input_tokens BIGINT, output_tokens BIGINT,
                               cache_read_input_tokens BIGINT,
                               cache_creation_input_tokens BIGINT))'
  }
)
WHERE regexp_matches(
  ltrim(filename[length(getvariable('mirror_dir')) + 1:], '/'),
  '^[^/]+/[^/]+\.jsonl$|^[^/]+/[^/]+/subagents/(.+/)?agent-[^/]+\.jsonl$'
);

-- ---------------------------------------------------------------------------
-- sessions: one row per sessionId (subagent files fold into their parent, so a
-- session spans the main file + its subagents). parent_session_id is NULL for
-- Claude Code -- CC has no session->session parent chain in these records; the
-- subagent linkage is carried at message grain via is_sidechain, not here.
CREATE OR REPLACE TABLE stg_sessions AS
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
  NULL::varchar                                                    AS pi_version,
  NULL::varchar                                                    AS oc_version,
  NULL::varchar                                                    AS agent,
  strftime(started_at, '%Y-%m-%d')                                 AS date
FROM matched;

-- ---------------------------------------------------------------------------
-- messages: one row per user/assistant line. message_id = line uuid (unique per
-- event); api_message_id = provider message.id (msg_...), nullable. Other record
-- types (system/mode/snapshot/...) are not messages and are skipped; the raw
-- JSONL remains the source of truth.
--
-- message.content is an array of blocks for tool-bearing turns and a bare string
-- for plain text. try_cast to json[] is NULL for anything that is not an array,
-- so the cast is safe wherever the planner puts it.
--
-- _cc_raw and the stg_ views below stay views: the corpus is parsed again by
-- each consumer, and nothing but the small stg_sessions and stg_api_calls is
-- held in the database, so a build's spill is its sort and join state and not
-- a copy of the corpus.
--
-- origin is structural: a row carrying a tool result is tool_result, whatever
-- else it holds. interrupted is a fact about the row: the interrupt marker is in
-- its text or in a tool result it carries. Whether the operator meant a
-- correction is judgment and stays in mining.
CREATE OR REPLACE VIEW stg_messages AS
WITH m AS (
  SELECT session_id, message_id, parent_id, is_sidechain, is_meta, timestamp, record_type, role,
         api_message_id, ctype, content_json,
         CASE WHEN ctype = 'ARRAY' THEN try_cast(content_json AS json[]) END AS blocks
  FROM (SELECT sessionId::varchar AS session_id, uuid::varchar AS message_id,
               parentUuid::varchar AS parent_id, coalesce(isSidechain, false) AS is_sidechain,
               coalesce(isMeta, false) AS is_meta,
               timestamp, type AS record_type, message.role AS role,
               message.id AS api_message_id,
               message.content::json AS content_json,
               json_type(message.content::json) AS ctype
        FROM _cc_raw
        WHERE type IN ('user','assistant') AND uuid IS NOT NULL
        QUALIFY row_number() OVER (PARTITION BY sessionId, uuid
                                   ORDER BY filename, timestamp, parentUuid NULLS LAST) = 1)
),
t AS (
  SELECT session_id, message_id, parent_id, is_sidechain, is_meta, timestamp, record_type, role,
         api_message_id,
         CASE WHEN ctype = 'ARRAY'
              THEN _join_blocks(list_transform(list_filter(blocks, lambda j: _block_type(j) = 'text'),
                                               lambda j: json_extract_string(j, '$.text')))
              WHEN ctype = 'VARCHAR' THEN json_extract_string(content_json, '$') END      AS text,
         coalesce(len(list_filter(blocks, lambda j: _block_type(j) = 'tool_result')) > 0, false)
                                                                                         AS has_tool_result,
         CASE WHEN ctype = 'ARRAY'
              THEN _join_blocks(list_transform(list_filter(blocks, lambda j: _block_type(j) = 'tool_result'),
                                               lambda j: (j -> 'content')::varchar)) END AS tool_result_txt
  FROM m
)
SELECT
  m.message_id,
  m.session_id,
  m.role,
  m.parent_id,
  m.is_sidechain,
  m.is_meta,
  m.timestamp,
  m.record_type,
  m.api_message_id,
  CASE WHEN m.has_tool_result THEN 'tool_result'
       WHEN m.role = 'user' THEN 'operator'
       WHEN m.role = 'assistant' THEN 'model' END                     AS origin,
  m.text,
  CASE WHEN m.role = 'user'
       THEN coalesce(m.text ILIKE '%[Request interrupted by user%'
                     OR m.tool_result_txt ILIKE '%Request interrupted by user%', false)
       ELSE false END                                                 AS interrupted,
  'claude-code'                                                       AS runtime,
  ss.date                                                             AS date
FROM t m
JOIN stg_sessions ss ON m.session_id = ss.session_id;

-- ---------------------------------------------------------------------------
-- api_calls: the ccusage UsageEntry spine. Dedup per (message.id, requestId)
-- taking MAX(output_tokens) (streaming final); input/cache are constant in a
-- group so MAX == the value. cost_usd computed from pricing.toml.
CREATE OR REPLACE TABLE stg_api_calls AS
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
    min(session_id)                AS session_id,
    any_value(model)               AS model,
    max_by(line_uuid, outp)        AS message_id,   -- representative line
    max_by(ts, outp)               AS timestamp,
    coalesce(max(inp), 0)          AS input,
    coalesce(max(outp), 0)         AS output,
    coalesce(max(cr), 0)           AS cache_read,
    coalesce(max(cw), 0)           AS cache_write
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
JOIN stg_sessions ss  ON d.session_id = ss.session_id;

-- ---------------------------------------------------------------------------

-- tool_calls: one row per (session_id, tool_use_id), a tool_use paired with its
-- tool_result. The first tool_use of an id (by timestamp, then message id) and its
-- first result (then block position) are kept; a repeat of either, as when a
-- source repeats lines, is dropped. A result with no tool_use gets a row of its
-- own with NULL tool_name, message_id and started_at. A tool_use with no result
-- has NULL outcome. Claude Code records
-- no tool timing, so ended_at and duration_ms are NULL.
--
-- Result content is a string or an array of items; the text items join like
-- message blocks.
--
-- One pass over the corpus keeps only the tool_use and tool_result blocks,
-- already reduced to the fields the table needs, so the window and the join
-- below never run beside a JSON reader.
--
-- json_transform reads each block into just the fields used here, so an image
-- payload in a result is never copied out. A json_extract per field copies the
-- payload once per field, and a run of image blocks then fills memory_limit
-- with transient vectors that cannot spill.
CREATE OR REPLACE TABLE _cc_tool AS
SELECT session_id, message_id, timestamp, i, bt,
       CASE WHEN bt = 'tool_use' THEN h.id ELSE h.tool_use_id END                            AS tool_use_id,
       CASE WHEN bt = 'tool_use' THEN h.name END                                             AS tool_name,
       CASE WHEN bt = 'tool_use' THEN h.input::varchar END                                   AS arguments,
       CASE WHEN bt = 'tool_result'
            THEN coalesce(try_cast(h.is_error AS BOOLEAN), false) END                        AS is_error,
       CASE WHEN bt = 'tool_result' THEN
         CASE json_type(blk, '$.content')
           WHEN 'ARRAY'
           THEN _join_blocks(list_transform(
                  list_filter(json_transform(blk, '{"content":[{"type":"VARCHAR","text":"VARCHAR"}]}').content,
                              lambda c: c.type = 'text'),
                  lambda c: c.text))
           WHEN 'VARCHAR' THEN json_extract_string(blk, '$.content') END
       END                                                                                   AS result_text
FROM (SELECT session_id, message_id, timestamp, record_type, i, blk, h.type AS bt, h
      FROM (SELECT session_id, message_id, timestamp, record_type, i, blk,
                   json_transform(blk, '{"type":"VARCHAR","id":"VARCHAR","name":"VARCHAR","tool_use_id":"VARCHAR","is_error":"VARCHAR","input":"JSON"}') AS h
            FROM (SELECT session_id, message_id, timestamp, record_type, blocks[i] AS blk, i
                  FROM (SELECT sessionId::varchar AS session_id, uuid::varchar AS message_id, timestamp,
                               type AS record_type, blocks,
                               unnest(generate_series(1, len(blocks))) AS i
                        FROM (SELECT *, try_cast(message.content::json AS json[]) AS blocks
                              FROM _cc_raw
                              WHERE type IN ('user','assistant') AND uuid IS NOT NULL
                                AND json_type(message.content::json) = 'ARRAY')))))
WHERE (bt = 'tool_use' AND record_type = 'assistant') OR bt = 'tool_result';


-- Outcome: an error result is denied when the tool refused to run on the
-- operator's say-so, cancelled when the operator interrupted it, else error.
CREATE OR REPLACE VIEW stg_tool_calls AS
WITH u AS (
  SELECT session_id, message_id, tool_use_id, tool_name,
         timestamp AS started_at, arguments,
         row_number() OVER (PARTITION BY session_id, tool_use_id
                            ORDER BY timestamp, message_id) AS urank
  FROM _cc_tool
  WHERE bt = 'tool_use'
),
r AS (
  SELECT session_id, message_id, tool_use_id, result_text,
         CASE WHEN NOT is_error THEN 'ok'
              WHEN starts_with(result_text, 'The user doesn''t want to proceed with this tool use') THEN 'denied'
              WHEN starts_with(result_text, '[Request interrupted by user') THEN 'cancelled'
              ELSE 'error' END AS outcome,
         row_number() OVER (PARTITION BY session_id, tool_use_id
                            ORDER BY timestamp, message_id, i) AS rn
  FROM _cc_tool WHERE bt = 'tool_result'
),
paired AS (
  SELECT coalesce(uu.session_id, rr.session_id) AS session_id, uu.message_id,
         coalesce(uu.tool_use_id, rr.tool_use_id) AS tool_use_id, uu.tool_name, uu.started_at,
         uu.arguments, rr.outcome, rr.result_text, rr.message_id AS result_message_id
  FROM (SELECT * FROM u WHERE urank = 1) uu
  FULL JOIN (SELECT * FROM r WHERE rn = 1) rr
    ON uu.session_id = rr.session_id AND uu.tool_use_id = rr.tool_use_id
)
SELECT
  p.session_id,
  p.message_id,
  p.tool_use_id,
  p.tool_name,
  p.started_at,
  NULL::timestamp                                                    AS ended_at,
  NULL::bigint                                                       AS duration_ms,
  p.outcome,
  p.arguments,
  p.result_text,
  p.result_message_id,
  'claude-code'                                                      AS runtime,
  ss.date                                                            AS date
FROM paired p
JOIN stg_sessions ss ON p.session_id = ss.session_id;
