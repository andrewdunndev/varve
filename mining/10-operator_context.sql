-- Saves operator_context: one row per user message of the runtimes mining
-- reads, with the context every detector needs. Reads messages, sessions,
-- api_calls, tool_calls and the patterns view.
--   body           text with the interrupt marker stripped
--   speech         what the operator said, for display only: the text, else the
--                  tool result the row carries; never part of a key
--   is_noise       injected text, by the noise patterns
--   is_operator    typed operator speech: not noise, not a tool result, not empty
--   interrupted    the adapter's interrupt fact
--   is_copy        the same message recorded under an earlier-started session
--   prior_asst_uuid  nearest preceding assistant message that carries text
--   model_id       model of the nearest api call at or before the message
-- pi is left out: its adapter is the least exercised, and mining is
-- precision-first.

CREATE TEMP TABLE _um AS
SELECT row_number() OVER () AS rid, message_id, session_id, timestamp AS ts, runtime,
       text AS raw_txt, (origin = 'tool_result') AS has_tool_result, interrupted
FROM messages
WHERE role = 'user'
  AND (runtime = 'claude-code' OR (runtime = 'opencode' AND text IS NOT NULL));

CREATE TEMP TABLE _noisy AS
SELECT DISTINCT u.rid
FROM _um u JOIN patterns p ON p.kind = 'noise' AND u.raw_txt ILIKE p.pattern;

SET VARIABLE interrupt_prefix = coalesce((SELECT any_value(pattern) FROM patterns WHERE kind = 'interrupt_prefix'), '$^');

CREATE TEMP TABLE _op AS
SELECT u.*,
       trim(regexp_replace(coalesce(u.raw_txt, ''), getvariable('interrupt_prefix'), '')) AS body,
       (u.rid IN (SELECT rid FROM _noisy)) AS is_noise
FROM _um u;

-- Assistant text, the draft being corrected. Same-timestamp ties keep the lowest message id.
CREATE TEMP TABLE _asst_txt AS
SELECT message_id, session_id, timestamp AS ts, runtime, text AS atxt
FROM messages
WHERE role = 'assistant' AND runtime IN ('claude-code', 'opencode')
  AND text IS NOT NULL AND length(trim(text)) > 0
QUALIFY row_number() OVER (PARTITION BY runtime, session_id, timestamp ORDER BY message_id) = 1;

CREATE TEMP TABLE _api AS
SELECT session_id, runtime, timestamp AS ts, min(model) AS model
FROM api_calls WHERE model IS NOT NULL GROUP BY ALL;

CREATE TEMP TABLE _op_ctx AS
SELECT
  o.*,
  a.message_id AS prior_asst_uuid,
  c.model      AS model_id,
  ((NOT o.is_noise) AND (NOT o.has_tool_result) AND length(trim(o.body)) > 0) AS is_operator
FROM _op o
ASOF LEFT JOIN _asst_txt a
  ON o.runtime = a.runtime AND o.session_id = a.session_id AND o.ts > a.ts
ASOF LEFT JOIN _api c
  ON o.runtime = c.runtime AND o.session_id = c.session_id AND o.ts >= c.ts;

-- A message recorded in more than one session (the same line uuid in two session
-- files) belongs to the earliest-started session; the other copies are flagged.
CREATE TEMP TABLE _copies AS
SELECT o.runtime, o.session_id, o.message_id
FROM (SELECT DISTINCT runtime, session_id, message_id FROM _op) o
JOIN sessions s ON s.runtime = o.runtime AND s.session_id = o.session_id
QUALIFY row_number() OVER (PARTITION BY o.runtime, o.message_id
                           ORDER BY s.started_at NULLS LAST, o.session_id) > 1;

CREATE TEMP TABLE _carried AS
SELECT runtime, session_id, result_message_id AS message_id,
       string_agg(result_text, chr(10)) AS result_txt
FROM tool_calls
WHERE runtime = 'claude-code' AND result_message_id IS NOT NULL
GROUP BY runtime, session_id, result_message_id;

CREATE TEMP TABLE mine_out AS
SELECT
  c.runtime, c.session_id, c.message_id, c.ts, c.body,
  trim(regexp_replace(
    coalesce(nullif(c.raw_txt, ''), regexp_replace(k.result_txt, '^.*?the user said:\s*', ''), c.raw_txt),
    getvariable('interrupt_prefix'), '')) AS speech,
  c.is_noise, c.has_tool_result, c.is_operator, c.interrupted,
  (cp.message_id IS NOT NULL) AS is_copy,
  c.prior_asst_uuid, c.model_id
FROM _op_ctx c
LEFT JOIN _carried k
  ON k.runtime = c.runtime AND k.session_id = c.session_id AND k.message_id = c.message_id
LEFT JOIN _copies cp
  ON cp.runtime = c.runtime AND cp.session_id = c.session_id AND cp.message_id = c.message_id;
