-- Saves operator_messages: the recall-floor denominator. One row per typed
-- operator message (the is_operator predicate of operator_context, copies,
-- subagent traffic and harness-written rows left out), flagged when any detector made it a candidate locus. Metadata
-- only: no text. tool_reject loci are tool-result carriers, never typed
-- speech, so they never set flagged.

CREATE TEMP TABLE mine_out AS
SELECT DISTINCT
  ctx.session_id, ctx.message_id AS message_uuid, ctx.ts,
  s.estate, s.harness, s.campaign,
  (fl.message_uuid IS NOT NULL) AS flagged,
  s.date AS date, ctx.runtime
FROM operator_context ctx
JOIN sessions s ON s.runtime = ctx.runtime AND s.session_id = ctx.session_id
LEFT JOIN (SELECT DISTINCT runtime, session_id, message_uuid FROM correction_candidates) fl
  ON fl.runtime = ctx.runtime AND fl.session_id = ctx.session_id AND fl.message_uuid = ctx.message_id
WHERE ctx.is_operator AND NOT ctx.is_copy AND NOT ctx.is_sidechain AND NOT ctx.is_meta;
