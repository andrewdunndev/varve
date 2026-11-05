-- varve GitHub Copilot CLI adapter (fork addition, 2026-11-04). Derives the four
-- normalized per-runtime staging tables (_cp_sessions, _cp_messages, _cp_api_calls,
-- _cp_tool_calls) plus a file->session->date map (_cp_files). sql/stage.sql unions
-- these into stg_*.
--
-- Two sources under the Copilot home (default ~/.copilot, VARVE_COPILOT_ROOT):
--   1. session-state/<session_id>/events.jsonl -- the full event stream, one JSON
--      object per line: {type, data, id, timestamp, parentId}. Primary source for
--      sessions, messages and tool_calls. ~60 event types observed (CLI 1.0.6x..1.0.9x);
--      the ones read here:
--        session.start            data.sessionId, data.copilotVersion, data.context.cwd
--        user.message             data.content (raw operator text; transformedContent
--                                 adds injected context and is NOT read)
--        assistant.message        data.content, data.apiCallId, data.parentToolCallId,
--                                 data.toolRequests[].toolCallId
--        abort                    data.reason {user_initiated|user_abort} -- interrupts
--        tool.execution_start     data.toolCallId, toolName, mcpServerName, mcpToolName,
--                                 arguments, parentToolCallId (set = subagent call)
--        tool.execution_complete  data.toolCallId, success, error{code,message},
--                                 result{content,...}
--        permission.completed     data.toolCallId, result.kind {approved |
--                                 approved-for-location | denied-interactively-by-user |
--                                 cancelled}
--      events.jsonl is read with an EXPLICIT column set and `data` kept as JSON:
--      read_json_auto + union_by_name over the whole corpus infers a giant struct and
--      runs out of memory (observed: 12 GB on a 578 MB corpus).
--   2. session-store.db (SQLite, WAL) -- ATTACHed read-only from a snapshot copy as
--      schema `cpdb` by the justfile (or stubbed empty by adapters/copilot_db_stub.sql
--      when absent). Supplies:
--        * api_calls: assistant_usage_events (one row per model call, ~5x the
--          coverage of the session.usage_record events, which only newer CLI builds emit)
--        * sessions + turns for sessions whose events.jsonl no longer exists.
--
-- Cost. Copilot bills premium requests (request_multiplier) / AI units
-- (total_nano_aiu), not per-token USD. cost_usd is the LIST-PRICE EQUIVALENT from the
-- shared pricing seed (model id normalized '.'->'-', e.g. claude-sonnet-4.6 ->
-- claude-sonnet-4-6); unseeded models stay 0 + unpriced_model. The native billing
-- units are kept as cp_premium_requests / cp_nano_aiu.
--
-- Token semantics. assistant_usage_events.input_tokens INCLUDES cache read+write
-- (verified: input 22125 = 2 fresh + 22123 cache_write). varve's `input` is fresh
-- input only (Anthropic convention), so input = input_tokens - cache_read - cache_write.
--
-- Depends on sql/prelude.sql (run first). Variables (set by the justfile):
--   copilot_events : glob of events.jsonl files
--   copilot_db     : path of the LIVE session-store.db (recorded in _cp_files so the
--                    manifest keys on the real file, not the snapshot) or '' if absent

-- ---------------------------------------------------------------------------
-- Raw events: EVERY line of every events.jsonl (all ~60 event types). The core
-- tables below read a subset; the full stream lands in copilot_events. The only
-- thing dropped is the base64 payload of session.binary_asset (pasted images);
-- its metadata (mimeType, byteLength, description) is kept.
CREATE OR REPLACE TABLE _cp_ev AS
SELECT
  regexp_extract(filename, '([^/]+)/events\.jsonl$', 1)  AS session_id,
  filename,
  type,
  CASE WHEN type = 'session.binary_asset'
       THEN json_merge_patch(data, '{"data":null}') ELSE data END AS data,
  id                                                      AS event_id,
  parentId                                                AS parent_event_id,
  try_cast(replace(timestamp, 'Z', '') AS timestamp)      AS ts,
  row_number() OVER (PARTITION BY filename)               AS line_no
FROM read_json(getvariable('copilot_events'),
  format = 'newline_delimited',
  columns = {type: 'VARCHAR', data: 'JSON', id: 'VARCHAR', timestamp: 'VARCHAR', parentId: 'VARCHAR'},
  filename = true, ignore_errors = true, maximum_object_size = getvariable('json_max_object'));

-- ---------------------------------------------------------------------------
-- sessions: events-backed sessions first; DB-only sessions (events.jsonl gone)
-- appended so their turns still reach correction mining.
CREATE OR REPLACE TABLE _cp_sessions AS
WITH ev_sess AS (
  SELECT session_id,
         any_value(data->'context'->>'cwd')  FILTER (WHERE type = 'session.start') AS cwd,
         any_value(data->>'copilotVersion')  FILTER (WHERE type = 'session.start') AS cp_version,
         min(ts)                                                                   AS started_at,
         true                                                                      AS cp_has_events
  FROM _cp_ev
  GROUP BY session_id
),
db_sess AS (
  SELECT id::varchar AS session_id, cwd,
         NULL::varchar AS cp_version,
         try_cast(replace(created_at, 'Z', '') AS timestamp) AS started_at,
         false AS cp_has_events
  FROM cpdb.sessions
  WHERE id::varchar NOT IN (SELECT session_id FROM ev_sess)
),
base AS (
  SELECT * FROM ev_sess UNION ALL BY NAME SELECT * FROM db_sess
),
matched AS (
  SELECT b.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM base b
  JOIN _attr_rules r
    ON coalesce(b.cwd, '') LIKE replace(r.cwd_glob, '*', '%')
  WHERE b.started_at IS NOT NULL
  QUALIFY row_number() OVER (PARTITION BY b.session_id ORDER BY r.priority) = 1
)
SELECT
  m.session_id,
  'copilot'                               AS runtime,
  m.cwd,
  varve_harness(m.cwd, m.harness_tok)     AS harness,
  m.estate,
  varve_campaign(m.cwd, m.campaign_tok)   AS campaign,
  m.started_at,
  NULL::varchar                           AS parent_session_id,
  m.cp_version,
  m.cp_has_events,
  d.summary                               AS cp_summary,
  strftime(m.started_at, '%Y-%m-%d')      AS date
FROM matched m
LEFT JOIN cpdb.sessions d ON d.id::varchar = m.session_id;

-- ---------------------------------------------------------------------------
-- messages. content = plain text (opencode-style, not CC block JSON). Abort events
-- land as role 'user' / record_type 'abort' / content NULL: they mark interrupts
-- without counting as operator speech. is_sidechain = emitted inside a subagent.
CREATE OR REPLACE TABLE _cp_messages AS
WITH ev_msgs AS (
  SELECT
    e.event_id                                            AS message_id,
    e.session_id,
    CASE e.type WHEN 'assistant.message' THEN 'assistant' ELSE 'user' END AS role,
    e.parent_event_id                                     AS parent_id,
    (e.data->>'parentToolCallId') IS NOT NULL             AS is_sidechain,
    e.ts                                                  AS timestamp,
    e.type                                                AS record_type,
    e.data->>'apiCallId'                                  AS api_message_id,
    CASE WHEN e.type = 'abort' THEN NULL
         ELSE nullif(e.data->>'content', '') END          AS content,
    CASE WHEN e.type = 'abort' THEN e.data->>'reason' END AS cp_abort_reason,
    e.data->>'model'                                      AS cp_model,
    -- user.message: the prompt as sent, with injected context (datetime, reminders)
    CASE WHEN e.type = 'user.message'
         THEN e.data->>'transformedContent' END           AS cp_transformed_content
  FROM _cp_ev e
  WHERE e.type IN ('user.message', 'assistant.message', 'abort')
),
-- DB-only sessions: each turn -> one user + one assistant row. The assistant row is
-- placed 1 ms after the user row so ASOF ordering (corrections.sql) sees draft
-- before the next correction.
db_turns AS (
  SELECT t.session_id::varchar AS session_id, t.turn_index,
         try_cast(replace(t.timestamp, 'Z', '') AS timestamp) AS ts,
         t.user_message, t.assistant_response
  FROM cpdb.turns t
  JOIN _cp_sessions s ON s.session_id = t.session_id::varchar AND NOT s.cp_has_events
),
db_msgs AS (
  SELECT session_id || ':t' || turn_index || ':u' AS message_id, session_id, 'user' AS role,
         NULL::varchar AS parent_id, false AS is_sidechain, ts AS timestamp,
         'db.turn.user' AS record_type, NULL::varchar AS api_message_id,
         nullif(user_message, '') AS content
  FROM db_turns
  UNION ALL
  SELECT session_id || ':t' || turn_index || ':a', session_id, 'assistant',
         session_id || ':t' || turn_index || ':u', false, ts + INTERVAL 1 MILLISECOND,
         'db.turn.assistant', NULL, nullif(assistant_response, '')
  FROM db_turns
)
SELECT m.*, 'copilot' AS runtime, s.date
FROM (SELECT * FROM ev_msgs UNION ALL BY NAME SELECT * FROM db_msgs) m
JOIN _cp_sessions s ON s.session_id = m.session_id;

-- ---------------------------------------------------------------------------
-- api_calls: one row per model call from session-store.db.
CREATE OR REPLACE TABLE _cp_api_calls AS
WITH u AS (
  SELECT
    a.session_id::varchar                                         AS session_id,
    'cp-usage-' || a.id                                           AS message_id,
    try_cast(replace(a.created_at, 'Z', '') AS timestamp)         AS timestamp,
    a.model,
    coalesce(a.cache_read_tokens, 0)::bigint                      AS cache_read,
    coalesce(a.cache_write_tokens, 0)::bigint                     AS cache_write,
    greatest(coalesce(a.input_tokens, 0) - coalesce(a.cache_read_tokens, 0)
             - coalesce(a.cache_write_tokens, 0), 0)::bigint      AS input,
    coalesce(a.output_tokens, 0)::bigint                          AS output,
    a.request_multiplier::double                                  AS cp_premium_requests,
    a.total_nano_aiu::bigint                                      AS cp_nano_aiu,
    a.initiator                                                   AS cp_initiator,
    a.finish_reason                                               AS cp_finish_reason,
    a.duration_ms::bigint                                         AS cp_duration_ms,
    a.agent_id IS NOT NULL                                        AS is_sidechain
  FROM cpdb.assistant_usage_events a
)
SELECT
  u.session_id,
  u.message_id,
  NULL::varchar                                AS api_message_id,
  NULL::varchar                                AS request_id,
  u.timestamp,
  u.model,
  'copilot'                                    AS provider,
  u.input, u.output, u.cache_read, u.cache_write,
  CASE WHEN p.model IS NOT NULL THEN round(
        u.input       * coalesce(p.input_cost, 0)
      + u.output      * coalesce(p.output_cost, 0)
      + u.cache_read  * coalesce(p.cache_read_cost, 0)
      + u.cache_write * coalesce(p.cache_creation_cost, 0), 6)
       ELSE 0 END                              AS cost_usd,
  (p.model IS NULL)                            AS unpriced_model,
  u.cp_premium_requests, u.cp_nano_aiu, u.cp_initiator, u.cp_finish_reason,
  u.cp_duration_ms, u.is_sidechain,
  'copilot'                                    AS runtime,
  s.date
FROM u
LEFT JOIN _pricing p ON replace(u.model, '.', '-') = p.model
JOIN _cp_sessions s  ON s.session_id = u.session_id
WHERE u.timestamp IS NOT NULL;

-- ---------------------------------------------------------------------------
-- tool_calls: execution_start LEFT JOIN execution_complete on (session, toolCallId),
-- plus the permission verdict. message_id = the assistant message that requested the
-- call (via toolRequests), else the start event id.
--
-- decision (aligned with opencode's vocabulary so D1 in corrections.sql can read it):
--   'denied'    -- operator denied the permission prompt (permission.completed
--                  result.kind = denied-*) or the tool reported error.code denied
--   'rejected'  -- tool reported error.code rejected
--   'cancelled' -- permission prompt cancelled
--   'completed' / 'error' -- executed, success true / false
--   'running'   -- no completion event (session killed mid-call)
-- Generic failure-analysis columns (nullable for other runtimes): mcp_server,
-- mcp_tool, arguments (JSON text), error_code, error_message, result_text (full
-- result.content -- vsp returns JSON here, so it must not be truncated),
-- result_detail (result.detailedContent, e.g. diffs), permission (raw kind).
CREATE OR REPLACE TABLE _cp_tool_calls AS
WITH st AS (
  SELECT session_id, event_id, ts,
         data->>'toolCallId'       AS tool_use_id,
         data->>'toolName'         AS tool_name,
         data->>'mcpServerName'    AS mcp_server,
         data->>'mcpToolName'      AS mcp_tool,
         (data->'arguments')::varchar AS arguments,
         data->>'model'            AS cp_model,
         (data->>'parentToolCallId') IS NOT NULL AS is_sidechain
  FROM _cp_ev WHERE type = 'tool.execution_start'
),
co AS (
  SELECT session_id, ts,
         data->>'toolCallId'                       AS tool_use_id,
         try_cast(data->>'success' AS boolean)     AS success,
         data->'error'->>'code'                    AS error_code,
         data->'error'->>'message'                 AS error_message,
         data->'result'->>'content'                AS result_text,
         data->'result'->>'detailedContent'        AS result_detail
  FROM _cp_ev WHERE type = 'tool.execution_complete'
  QUALIFY row_number() OVER (PARTITION BY session_id, data->>'toolCallId' ORDER BY ts DESC) = 1
),
pe AS (
  SELECT session_id, data->>'toolCallId' AS tool_use_id,
         data->'result'->>'kind'           AS permission
  FROM _cp_ev WHERE type = 'permission.completed'
  QUALIFY row_number() OVER (PARTITION BY session_id, data->>'toolCallId' ORDER BY ts DESC) = 1
),
req_all AS (
  SELECT session_id, event_id AS message_id, ts,
         unnest(json_extract_string(data, '$.toolRequests[*].toolCallId')) AS tool_use_id
  FROM _cp_ev WHERE type = 'assistant.message'
),
req AS (
  SELECT * FROM req_all
  QUALIFY row_number() OVER (PARTITION BY session_id, tool_use_id ORDER BY ts) = 1
)
SELECT
  st.session_id,
  coalesce(req.message_id, st.event_id)             AS message_id,
  st.tool_use_id,
  st.tool_name,
  st.ts                                              AS started_at,
  co.ts                                              AS ended_at,
  CASE WHEN co.ts IS NOT NULL
       THEN datediff('millisecond', st.ts, co.ts) END AS duration_ms,
  CASE
    WHEN pe.permission LIKE 'denied%' OR co.error_code = 'denied' THEN 'denied'
    WHEN co.error_code = 'rejected'                               THEN 'rejected'
    WHEN pe.permission = 'cancelled'                              THEN 'cancelled'
    WHEN co.success                                               THEN 'completed'
    WHEN co.success = false                                       THEN 'error'
    ELSE 'running'
  END                                                AS decision,
  st.mcp_server, st.mcp_tool, st.arguments,
  co.error_code, co.error_message, co.result_text, co.result_detail,
  pe.permission,
  st.cp_model, st.is_sidechain,
  'copilot'                                          AS runtime,
  s.date
FROM st
LEFT JOIN co  ON co.session_id = st.session_id AND co.tool_use_id = st.tool_use_id
LEFT JOIN pe  ON pe.session_id = st.session_id AND pe.tool_use_id = st.tool_use_id
LEFT JOIN req ON req.session_id = st.session_id AND req.tool_use_id = st.tool_use_id
JOIN _cp_sessions s ON s.session_id = st.session_id;

-- ---------------------------------------------------------------------------
-- file -> session -> date map. Each events.jsonl maps to its own session; the
-- LIVE db path maps to every copilot session (a db change re-derives them all,
-- same model as opencode -- the corpus is small).
CREATE OR REPLACE TABLE _cp_files AS
SELECT DISTINCT e.filename AS path, e.session_id, s.date
FROM _cp_ev e JOIN _cp_sessions s ON s.session_id = e.session_id
UNION
SELECT getvariable('copilot_db') AS path, session_id, date
FROM _cp_sessions
WHERE coalesce(getvariable('copilot_db'), '') <> '';

-- ===========================================================================
-- Copilot-only tables (no cross-runtime equivalent). Written to the lake as
-- copilot_events / copilot_checkpoints / copilot_session_files /
-- copilot_session_refs / copilot_artifacts, partitioned like the core tables.
-- ===========================================================================

-- Every event, verbatim (data as JSON text). The core tables are projections of
-- this; anything they do not model (model.turn_failed, session.error,
-- compaction, truncation, subagent.*, hook.*, skill.*, usage_checkpoint, ...)
-- is queried from here.
CREATE OR REPLACE TABLE _cp_events AS
SELECT e.session_id, e.line_no, e.event_id, e.parent_event_id, e.type, e.ts,
       e.data::varchar AS data, 'copilot' AS runtime, s.date
FROM _cp_ev e JOIN _cp_sessions s ON s.session_id = e.session_id;

-- Compaction checkpoints (session-store.db): the CLI's own structured summary of
-- a session at each compaction -- overview / history / work_done / technical
-- details / important files / next steps.
CREATE OR REPLACE TABLE _cp_checkpoints AS
SELECT c.session_id::varchar AS session_id, c.checkpoint_number, c.title, c.overview,
       c.history, c.work_done, c.technical_details, c.important_files, c.next_steps,
       try_cast(replace(c.created_at, 'Z', '') AS timestamp) AS created_at,
       'copilot' AS runtime, s.date
FROM cpdb.checkpoints c JOIN _cp_sessions s ON s.session_id = c.session_id::varchar;

-- Files a session touched, and git refs (commits) it produced.
CREATE OR REPLACE TABLE _cp_session_files AS
SELECT f.session_id::varchar AS session_id, f.file_path, f.tool_name, f.turn_index,
       try_cast(replace(f.first_seen_at, 'Z', '') AS timestamp) AS first_seen_at,
       'copilot' AS runtime, s.date
FROM cpdb.session_files f JOIN _cp_sessions s ON s.session_id = f.session_id::varchar;

CREATE OR REPLACE TABLE _cp_session_refs AS
SELECT r.session_id::varchar AS session_id, r.ref_type, r.ref_value, r.turn_index,
       try_cast(replace(r.created_at, 'Z', '') AS timestamp) AS created_at,
       'copilot' AS runtime, s.date
FROM cpdb.session_refs r JOIN _cp_sessions s ON s.session_id = r.session_id::varchar;

-- Workspace artifacts: every other file in session-state/<id>/ -- workspace.yaml,
-- plan.md, checkpoints/*.md, files/** (handoffs, scratch code), rewind-snapshots/**
-- (pre-edit file backups + index.json). Excluded: events.jsonl (above), the
-- per-session session.db (workflow store, empty in this corpus) and lock files.
-- content = UTF-8 text when the file decodes and is <= 1 MB, else NULL (size kept).
CREATE OR REPLACE TABLE _cp_artifacts AS
WITH b AS (
  SELECT filename AS path, size, last_modified, content
  FROM read_blob(getvariable('copilot_state') || '/*/**')
  WHERE filename NOT LIKE '%/events.jsonl'
    AND filename NOT LIKE '%/session.db%'
    AND filename NOT SIMILAR TO '.*\.(lock|hold)$'
)
SELECT
  regexp_extract(b.path, '/session-state/([^/]+)/', 1)              AS session_id,
  b.path,
  regexp_extract(b.path, '/session-state/[^/]+/(.*)$', 1)           AS rel_path,
  CASE
    WHEN b.path LIKE '%/rewind-snapshots/%' THEN 'rewind_snapshot'
    WHEN b.path LIKE '%/checkpoints/%'      THEN 'checkpoint'
    WHEN b.path LIKE '%/files/%'            THEN 'workspace_file'
    ELSE 'session_meta' END                                         AS kind,
  b.size::bigint                                                    AS size,
  b.last_modified::timestamp                                        AS modified_at,
  CASE WHEN b.size <= 1048576 THEN try(decode(b.content)) END       AS content,
  'copilot'                                                         AS runtime,
  s.date
FROM b JOIN _cp_sessions s
  ON s.session_id = regexp_extract(b.path, '/session-state/([^/]+)/', 1);

INSERT INTO _cp_files
SELECT DISTINCT path, session_id, date FROM _cp_artifacts;

DROP TABLE _cp_ev;
