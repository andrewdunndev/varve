-- varve Claude Code adapter. Near-pure SQL, per ADR-0002. Reads the retained
-- Claude Code JSONL, a Parquet table of its lines (ADR-0011), and derives the
-- four normalized tables stg_sessions, stg_messages, stg_api_calls and
-- stg_tool_calls; the build copies them to the lake.
--
-- Depends on sql/prelude.sql (run first): _attr_rules, _pricing, varve_harness(),
-- varve_campaign(). Variable set by the build:
--   mirror_dir : this runtime's mirror folder (no trailing slash); its lines/
--                tables hold (rel_path, line_no, line): one line of a source file
--
-- Source shape (Claude Code v2.1.x):
--   * ~/.claude/projects/<dashed-cwd>/<session_id>.jsonl  = main session
--   * .../<session_id>/subagents/agent-*.jsonl            = subagent (sidechain)
--     traffic; these carry the SAME sessionId as the parent, isSidechain=true.
--     The path filter therefore MUST admit subagents/ or subagent api
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
-- _cc_line: the retained lines of the session and subagent files, valid JSON only.
-- An image block carries its base64 payload inline, up to megabytes a line, and a
-- JSON parse copies it into vectors that cannot spill: a scan of a few image-heavy
-- buckets alone fills memory_limit. No table reads the payload (an interrupt marker
-- is not base64), so it is cut from the line before any parse, and only on lines
-- that name a base64 source.
--
-- Each view that parses ends its subquery in a LIMIT that never cuts: a filter above
-- the parse is otherwise rewritten into the parse itself, and the optimizer then
-- evaluates json_transform once per predicate term besides the projection, three
-- parses of every line held at once. The streaming limit stops that rewrite.
CREATE OR REPLACE VIEW _cc_line AS
SELECT rel_path, line_no, line
FROM (SELECT rel_path, line_no,
             CASE WHEN contains(line, '"base64"')
                  THEN regexp_replace(line, '("type":"base64","media_type":"[^"]*","data":")[A-Za-z0-9+/=]*"', '\1"', 'g')
                  ELSE line END AS line
      FROM read_parquet(getvariable('mirror_dir') || '/lines/*/*.parquet')
      WHERE regexp_matches(rel_path, '^[^/]+/[^/]+\.jsonl$|^[^/]+/[^/]+/subagents/(.+/)?agent-[^/]+\.jsonl$')
      LIMIT 9223372036854775807)
WHERE json_valid(line);

-- Raw read of those lines, each parsed with an explicit schema: inference
-- over the whole corpus collapses to a single MAP column once rare top-level
-- keys accumulate. Only main session files (<project>/<id>.jsonl) and subagent
-- transcripts are read; other JSONL (workflow journals, tool output) is skipped,
-- and so is a line that is not valid JSON. Values that do not fit the schema
-- read as NULL.
CREATE OR REPLACE VIEW _cc_raw AS
SELECT rel_path AS filename, line_no, unnest(j)
FROM (
  SELECT rel_path, line_no,
         json_transform(line, '{"sessionId":"VARCHAR","cwd":"VARCHAR","timestamp":"TIMESTAMP","version":"VARCHAR","uuid":"VARCHAR","parentUuid":"VARCHAR","isSidechain":"BOOLEAN","isMeta":"BOOLEAN","type":"VARCHAR","requestId":"VARCHAR","message":{"role":"VARCHAR","id":"VARCHAR","model":"VARCHAR","usage":{"input_tokens":"BIGINT","output_tokens":"BIGINT","cache_read_input_tokens":"BIGINT","cache_creation_input_tokens":"BIGINT"}}}') AS j
  FROM _cc_line
  LIMIT 9223372036854775807
);

-- The same with message.content, read only where a message is built: carrying the
-- content through the scans that need only the scalars doubles what each chunk holds.
CREATE OR REPLACE VIEW _cc_msg AS
SELECT rel_path AS filename, line_no, unnest(j)
FROM (
  SELECT rel_path, line_no,
         json_transform(line, '{"sessionId":"VARCHAR","cwd":"VARCHAR","timestamp":"TIMESTAMP","version":"VARCHAR","uuid":"VARCHAR","parentUuid":"VARCHAR","isSidechain":"BOOLEAN","isMeta":"BOOLEAN","type":"VARCHAR","requestId":"VARCHAR","message":{"role":"VARCHAR","id":"VARCHAR","model":"VARCHAR","content":"JSON","usage":{"input_tokens":"BIGINT","output_tokens":"BIGINT","cache_read_input_tokens":"BIGINT","cache_creation_input_tokens":"BIGINT"}}}') AS j
  FROM _cc_line
  LIMIT 9223372036854775807
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
-- for plain text. The array is read once into typed blocks, and a value that is not
-- an array reads as NULL; each JSON function in a pipeline holds the parse of its
-- last chunk, so one parse of the content serves every use of it.
--
-- _cc_raw, _cc_msg and the stg_ views below stay views: the corpus is parsed again by
-- each consumer, and nothing but the small stg_sessions and stg_api_calls is
-- held in the database, so a build's spill is its sort and join state and not
-- a copy of the corpus.
--
-- One line stands for each (session, uuid): the earliest file, then timestamp. The
-- lines that lose are few (_cc_dup, found by a window over the keys alone), so the
-- messages scan only drops them and no window or sort holds message text.
CREATE OR REPLACE TABLE _cc_dup AS
SELECT filename, line_no
FROM (SELECT filename, line_no,
             row_number() OVER (PARTITION BY sessionId, uuid
                                ORDER BY filename, timestamp, parentUuid NULLS LAST) AS rn
      FROM _cc_raw
      WHERE type IN ('user','assistant') AND uuid IS NOT NULL)
WHERE rn > 1;

-- origin is structural: a row carrying a tool result is tool_result, whatever
-- else it holds. interrupted is a fact about the row: the interrupt marker is in
-- its text or in a tool result it carries. Whether the operator meant a
-- correction is judgment and stays in mining.
-- The messages are parsed on one thread, as the tool calls are below, into a file
-- in the run's temp directory that stg_messages reads back.
SET VARIABLE cc_msg = current_setting('temp_directory') || '/_cc_msg.parquet';
SET VARIABLE cc_threads = current_setting('threads');
SET threads = 1;
COPY (
WITH m AS (
  SELECT session_id, message_id, parent_id, is_sidechain, is_meta, timestamp, record_type, role,
         api_message_id, ctype, content_json,
         CASE WHEN ctype = 'ARRAY'
              THEN json_transform(content_json, '[{"type":"VARCHAR","text":"VARCHAR","content":"JSON"}]') END AS blocks
  FROM (SELECT sessionId::varchar AS session_id, uuid::varchar AS message_id,
               parentUuid::varchar AS parent_id, coalesce(isSidechain, false) AS is_sidechain,
               coalesce(isMeta, false) AS is_meta,
               timestamp, type AS record_type, message.role AS role,
               message.id AS api_message_id,
               message.content::json AS content_json,
               CASE left(message.content::varchar, 1) WHEN '[' THEN 'ARRAY' WHEN '"' THEN 'VARCHAR' END AS ctype
        FROM _cc_msg ANTI JOIN _cc_dup USING (filename, line_no)
        WHERE type IN ('user','assistant') AND uuid IS NOT NULL)
),
t AS (
  SELECT session_id, message_id, parent_id, is_sidechain, is_meta, timestamp, record_type, role,
         api_message_id,
         CASE WHEN ctype = 'ARRAY'
              THEN _join_blocks(list_transform(list_filter(blocks, lambda b: b.type = 'text'), lambda b: b.text))
              WHEN ctype = 'VARCHAR' THEN json_extract_string(content_json, '$') END      AS text,
         coalesce(len(list_filter(blocks, lambda b: b.type = 'tool_result')) > 0, false)
                                                                                         AS has_tool_result,
         CASE WHEN ctype = 'ARRAY'
              THEN list_bool_or(list_transform(list_filter(blocks, lambda b: b.type = 'tool_result'),
                                               lambda b: regexp_matches(b.content::varchar, '(?i)Request interrupted by user'))) END
                                                                                         AS tool_result_interrupted
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
                     OR m.tool_result_interrupted, false)
       ELSE false END                                                 AS interrupted
FROM t m)
TO (getvariable('cc_msg')) (FORMAT parquet, ROW_GROUP_SIZE 20000, ROW_GROUP_SIZE_BYTES '16MB');
SET threads = getvariable('cc_threads');

CREATE OR REPLACE VIEW stg_messages AS
SELECT m.*, 'claude-code' AS runtime, ss.date AS date
FROM read_parquet(getvariable('cc_msg')) m
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
-- The blocks are read from the line by one json_transform, into just the fields used
-- here: an image payload in a result is never copied out (a json_extract per field
-- copies it once per field), and the big text is parsed once, since each JSON
-- function in a pipeline holds the parse of its last chunk. Content that is not an
-- array reads as NULL. Only lines that carry a tool block are read.
CREATE OR REPLACE VIEW _cc_traw AS
SELECT rel_path AS filename, unnest(j)
FROM (SELECT rel_path,
             json_transform(line, '{"sessionId":"VARCHAR","timestamp":"TIMESTAMP","uuid":"VARCHAR","type":"VARCHAR","message":{"content":[{"type":"VARCHAR","id":"VARCHAR","name":"VARCHAR","tool_use_id":"VARCHAR","is_error":"VARCHAR","input":"JSON","content":"JSON"}]}}') AS j
      FROM _cc_line
      WHERE contains(line, '"tool_use"') OR contains(line, '"tool_result"')
      LIMIT 9223372036854775807);

-- The paired rows are about 2 GB of text on a large corpus: they go to a file in the
-- run's temp directory and are read back, not held as a table beside the window
-- and join below. It runs on one thread: each thread holds the chunk it is parsing, a
-- line of megabytes among them, and the blocks, their copies and the write buffer
-- come to more than the second thread can be given.
SET VARIABLE cc_tool = current_setting('temp_directory') || '/_cc_tool.parquet';
SET VARIABLE cc_threads = current_setting('threads');
SET threads = 1;
COPY (
SELECT session_id, message_id, timestamp, i, bt,
       CASE WHEN bt = 'tool_use' THEN b.id ELSE b.tool_use_id END                            AS tool_use_id,
       CASE WHEN bt = 'tool_use' THEN b.name END                                             AS tool_name,
       CASE WHEN bt = 'tool_use' THEN b.input::varchar END                                   AS arguments,
       CASE WHEN bt = 'tool_result'
            THEN coalesce(try_cast(b.is_error AS BOOLEAN), false) END                        AS is_error,
       CASE WHEN bt = 'tool_result' THEN
         CASE left(b.content::varchar, 1)
           WHEN '['
           THEN _join_blocks(list_transform(
                  list_filter(json_transform(b.content, '[{"type":"VARCHAR","text":"VARCHAR"}]'),
                              lambda c: c.type = 'text'),
                  lambda c: c.text))
           WHEN '"' THEN json_extract_string(b.content, '$') END
       END                                                                                   AS result_text
FROM (SELECT sessionId::varchar AS session_id, uuid::varchar AS message_id, timestamp,
             type AS record_type, b.type AS bt, i, b
      FROM (SELECT sessionId, uuid, timestamp, type, unnest(message.content) AS b,
                   unnest(generate_series(1, len(message.content))) AS i
            FROM _cc_traw
            WHERE type IN ('user','assistant') AND uuid IS NOT NULL))
WHERE (bt = 'tool_use' AND record_type = 'assistant') OR bt = 'tool_result')
TO (getvariable('cc_tool')) (FORMAT parquet, ROW_GROUP_SIZE 20000, ROW_GROUP_SIZE_BYTES '16MB');
SET threads = getvariable('cc_threads');
CREATE OR REPLACE VIEW _cc_tool AS
SELECT *, file_row_number AS rid FROM read_parquet(getvariable('cc_tool'), file_row_number = true);

-- The first tool_use of an id and its first result stand; a repeat is found by a
-- window over the keys alone, and is few, so the wide rows are only filtered.
CREATE OR REPLACE TABLE _cc_tool_dup AS
SELECT rid
FROM (SELECT rid, row_number() OVER (PARTITION BY session_id, tool_use_id, bt
                                     ORDER BY timestamp, message_id, i) AS rn
      FROM _cc_tool)
WHERE rn > 1;


-- The pairing runs on the keys alone, as ids of the file's rows, and the text is
-- fetched by id after: a join of the full rows holds the arguments or the results of
-- every call in a hash table.
--
-- Outcome: an error result is denied when the tool refused to run on the
-- operator's say-so, cancelled when the operator interrupted it, else error.
CREATE OR REPLACE VIEW stg_tool_calls AS
WITH u AS (
  SELECT rid, session_id, tool_use_id
  FROM _cc_tool ANTI JOIN _cc_tool_dup USING (rid)
  WHERE bt = 'tool_use'
),
r AS (
  SELECT rid, session_id, tool_use_id
  FROM _cc_tool ANTI JOIN _cc_tool_dup USING (rid)
  WHERE bt = 'tool_result'
),
pairs AS (
  SELECT uu.rid AS urid, rr.rid AS rrid,
         coalesce(uu.session_id, rr.session_id) AS session_id,
         coalesce(uu.tool_use_id, rr.tool_use_id) AS tool_use_id
  FROM u uu
  FULL JOIN r rr
    ON uu.session_id = rr.session_id AND uu.tool_use_id = rr.tool_use_id
),
paired AS (
  SELECT p.session_id, uu.message_id, p.tool_use_id, uu.tool_name, uu.timestamp AS started_at,
         uu.arguments,
         CASE WHEN p.rrid IS NULL THEN NULL
              WHEN NOT rr.is_error THEN 'ok'
              WHEN starts_with(rr.result_text, 'The user doesn''t want to proceed with this tool use') THEN 'denied'
              WHEN starts_with(rr.result_text, '[Request interrupted by user') THEN 'cancelled'
              ELSE 'error' END AS outcome,
         rr.result_text, rr.message_id AS result_message_id
  FROM pairs p
  LEFT JOIN (SELECT rid, message_id, is_error, result_text FROM _cc_tool WHERE bt = 'tool_result') rr
    ON rr.rid = p.rrid
  LEFT JOIN (SELECT rid, message_id, tool_name, timestamp, arguments FROM _cc_tool WHERE bt = 'tool_use') uu
    ON uu.rid = p.urid
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
