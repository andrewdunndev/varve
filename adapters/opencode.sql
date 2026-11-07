-- varve opencode adapter. Reads the mirrored opencode SQLite store through the
-- sqlite extension and derives the four normalized tables stg_sessions,
-- stg_messages, stg_api_calls and stg_tool_calls; the build copies them to the
-- lake.
--
-- Depends on sql/prelude.sql (run first): _attr_rules, _pricing, varve_harness(),
-- varve_campaign(). Variable set by the build:
--   mirror_dir : this runtime's mirror folder; opencode.db sits directly in it
--
-- Source shape (opencode V1 tables):
--   * V1 contract tables: session / message / part (ADR-0006 -- pinned; the V2
--     event tables are maintainer-declared disposable and NOT read).
--   * session(id, parent_id, directory, version, agent, model, time_created ms)
--     -- opencode DOES chain sessions (parent_id), so parent_session_id is
--     populated here (unlike Claude Code). directory is the cwd (0 nulls).
--   * message(id, session_id, time_created ms, data JSON). data.role in
--     {user, assistant}. Assistant data carries the rolled-up cost + tokens for
--     the whole message: {"role":"assistant","modelID","providerID",
--     "time":{"created","completed"},"cost":<usd>,"tokens":{"input","output",
--     "reasoning","cache":{"read","write"}},...}.
--   * part(id, message_id, session_id, time_created ms, data JSON). data.type in
--     {tool, step-start, step-finish, text, patch, reasoning, ...}. Tool parts:
--     {"type":"tool","callID","tool","state":{"status","input","output","error",
--     "time":{"start","end"}}}.
--     step-finish parts carry PER-STEP cost/tokens -- deliberately NOT read for
--     api_calls (the assistant MESSAGE already sums them; reading step-finish too
--     would double-count).
--
-- Cost (cost:0 defense, ADR-0006). Assistant data.cost is authoritative when
-- present and > 0 -> use it. Some rows record cost 0 (the historic opencode
-- discrepancy, and subscription-billed models with no per-token price). When
-- the inline cost is 0/absent AND the model is in the pricing table, compute from
-- tokens x pricing table. When 0/absent AND unpriced (subscription/gpt/gemini not in the pricing table),
-- keep 0 and flag unpriced_model -- fabricating a per-token cost for a
-- subscription model would be wrong.
--
INSTALL sqlite;
LOAD sqlite;
CREATE OR REPLACE VIEW oc_session AS SELECT * FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'session');
CREATE OR REPLACE VIEW oc_message AS SELECT * FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'message');
CREATE OR REPLACE VIEW oc_part    AS SELECT * FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'part');

-- ---------------------------------------------------------------------------
-- sessions: one row per session. cwd = directory; attribution via the shared
-- rules/macros. parent_session_id populated from the session parent chain.
CREATE OR REPLACE TABLE stg_sessions AS
WITH base AS (
  SELECT id::varchar                       AS session_id,
         directory                         AS cwd,
         to_timestamp(time_created/1000.0) AS started_at,
         parent_id::varchar                AS parent_session_id,
         version                           AS oc_version,
         agent                             AS agent
  FROM oc_session
  WHERE time_created IS NOT NULL
),
matched AS (
  SELECT b.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM base b
  JOIN _attr_rules r
    ON coalesce(b.cwd,'') LIKE replace(r.cwd_glob, '*', '%')
  QUALIFY row_number() OVER (PARTITION BY b.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'opencode'                            AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)       AS harness,
  estate,
  varve_campaign(cwd, campaign_tok)     AS campaign,
  started_at::timestamp                 AS started_at,
  parent_session_id,
  NULL::varchar                         AS cc_version,
  NULL::varchar                         AS pi_version,
  oc_version,
  agent,
  strftime(started_at, '%Y-%m-%d')      AS date
FROM matched;

-- ---------------------------------------------------------------------------
-- messages: one row per message (all roles). opencode keeps text in `part`, not
-- on the message, so text is the message's text and reasoning parts joined in
-- part order. Reasoning parts stay in: dropping them would move the prior-draft
-- token sets the rewrite detector compares. is_sidechain is false -- opencode
-- has no sidechain flag; its parent/child structure lives at SESSION grain
-- (parent_id). interrupted is NULL: opencode records no interrupt signal that a
-- query reads.
CREATE OR REPLACE TABLE stg_messages AS
WITH txt AS (
  SELECT message_id,
         string_agg(json_extract_string(data, '$.text'), '\n' ORDER BY time_created, id) AS text
  FROM oc_part
  WHERE json_extract_string(data, '$.type') IN ('text','reasoning')
    AND json_extract_string(data, '$.text') IS NOT NULL
  GROUP BY message_id
)
SELECT
  m.id::varchar                                    AS message_id,
  m.session_id::varchar                            AS session_id,
  json_extract_string(m.data, '$.role')            AS role,
  json_extract_string(m.data, '$.parentID')        AS parent_id,
  false                                            AS is_sidechain,
  to_timestamp(m.time_created/1000.0)::timestamp   AS timestamp,
  json_extract_string(m.data, '$.role')            AS record_type,
  NULL::varchar                                    AS api_message_id,
  CASE json_extract_string(m.data, '$.role')
    WHEN 'user' THEN 'operator'
    WHEN 'assistant' THEN 'model' END              AS origin,
  txt.text                                         AS text,
  NULL::boolean                                    AS interrupted,
  'opencode'                                       AS runtime,
  ss.date                                          AS date
FROM oc_message m
JOIN stg_sessions ss ON m.session_id::varchar = ss.session_id
LEFT JOIN txt ON txt.message_id = m.id;

-- ---------------------------------------------------------------------------
-- api_calls: the ccusage UsageEntry spine. Grain = one assistant MESSAGE (the
-- rolled-up cost/tokens live there; per-step step-finish parts are not read to
-- avoid double counting). cache read/write map to the nested
-- tokens.cache.{read,write}.
CREATE OR REPLACE TABLE stg_api_calls AS
WITH asst AS (
  SELECT
    m.session_id::varchar                                        AS session_id,
    m.id::varchar                                                AS message_id,
    to_timestamp(json_extract(m.data,'$.time.created')::bigint/1000.0)::timestamp AS timestamp,
    json_extract_string(m.data,'$.modelID')                      AS model,
    json_extract_string(m.data,'$.providerID')                   AS provider,
    coalesce(json_extract(m.data,'$.tokens.input')::bigint,0)        AS input,
    coalesce(json_extract(m.data,'$.tokens.output')::bigint,0)       AS output,
    coalesce(json_extract(m.data,'$.tokens.cache.read')::bigint,0)   AS cache_read,
    coalesce(json_extract(m.data,'$.tokens.cache.write')::bigint,0)  AS cache_write,
    try_cast(json_extract(m.data,'$.cost') AS double)            AS inline_cost
  FROM oc_message m
  WHERE json_extract_string(m.data,'$.role') = 'assistant'
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
  -- cost:0 defense: trust inline cost when > 0; else compute from pricing table if the
  -- model is priced; else keep the runtime's 0 (unpriced/subscription).
  CASE
    WHEN a.inline_cost IS NOT NULL AND a.inline_cost > 0 THEN a.inline_cost
    WHEN p.model IS NOT NULL THEN round(
        a.input       * coalesce(p.input_cost,0)
      + a.output      * coalesce(p.output_cost,0)
      + a.cache_read  * coalesce(p.cache_read_cost,0)
      + a.cache_write * coalesce(p.cache_creation_cost,0), 6)
    ELSE coalesce(a.inline_cost, 0)
  END                                        AS cost_usd,
  (p.model IS NULL)                          AS unpriced_model,
  'opencode'                                 AS runtime,
  ss.date                                    AS date
FROM asst a
LEFT JOIN _pricing p    ON a.model = p.model
JOIN stg_sessions ss    ON a.session_id = ss.session_id;

-- ---------------------------------------------------------------------------
-- tool_calls: one row per tool part. opencode is the ONLY runtime with real
-- tool timing -- started_at/ended_at from state.time.{start,end} (epoch ms),
-- duration_ms their delta (NULL when either endpoint is absent). outcome maps
-- state.status: completed is ok, error is error, running and pending are
-- running, a refusal status is denied, anything else NULL. arguments is
-- state.input; result_text is state.output, else state.error. result_message_id
-- is the call's message once a result exists, NULL while running or unknown.
CREATE OR REPLACE TABLE stg_tool_calls AS
WITH tool AS (
  SELECT
    session_id::varchar                                    AS session_id,
    message_id::varchar                                    AS message_id,
    json_extract_string(data,'$.callID')                   AS tool_use_id,
    json_extract_string(data,'$.tool')                     AS tool_name,
    json_extract(data,'$.state.time.start')::bigint        AS t_start,
    json_extract(data,'$.state.time.end')::bigint          AS t_end,
    CASE lower(json_extract_string(data,'$.state.status'))
      WHEN 'completed' THEN 'ok'
      WHEN 'error' THEN 'error'
      WHEN 'running' THEN 'running'
      WHEN 'pending' THEN 'running'
      WHEN 'rejected' THEN 'denied'
      WHEN 'denied' THEN 'denied'
      WHEN 'declined' THEN 'denied'
      WHEN 'reject' THEN 'denied'
      WHEN 'deny' THEN 'denied'
    END                                                    AS outcome,
    json_extract(data,'$.state.input')::varchar            AS arguments,
    coalesce(json_extract_string(data,'$.state.output'),
             json_extract_string(data,'$.state.error'))    AS result_text
  FROM oc_part
  WHERE json_extract_string(data,'$.type') = 'tool'
)
SELECT
  t.session_id,
  t.message_id,
  t.tool_use_id,
  t.tool_name,
  to_timestamp(t.t_start/1000.0)::timestamp                AS started_at,
  to_timestamp(t.t_end/1000.0)::timestamp                  AS ended_at,
  CASE WHEN t.t_start IS NOT NULL AND t.t_end IS NOT NULL
       THEN (t.t_end - t.t_start)::bigint END              AS duration_ms,
  t.outcome,
  t.arguments,
  t.result_text,
  CASE WHEN t.outcome IS NOT NULL AND t.outcome <> 'running' THEN t.message_id END AS result_message_id,
  'opencode'                                               AS runtime,
  ss.date                                                  AS date
FROM tool t
JOIN stg_sessions ss ON t.session_id = ss.session_id;
