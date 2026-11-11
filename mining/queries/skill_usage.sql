-- QUESTION: Which skills fire, and what happens around them? How often per ISO
--   week and runtime, how often the operator corrects soon after, how often tools
--   fail or are refused while one is active.
-- METRIC: An invocation is one row in `inv`, by invocation_channel:
--   model_tool       the model called the skill tool (claude-code Skill, opencode skill)
--                    and the call succeeded (outcome ok); failed calls are not skills.
--   slash_command    the operator typed /<name> (a <command-name> tag) and the harness
--                    answered with a skill expansion (an is_meta row starting "Base
--                    directory for this skill:") before the next operator message. A
--                    built-in such as /compact gets no expansion and never counts, even
--                    when a skill shares its name. No name list is involved.
--   skill_file_read  a Read of .../skills/<name>/SKILL.md. Often authoring, not use.
--                    Bash cat reads of the same path are not counted.
--   A tool call or slash message recorded in more than one session (a resumed copy)
--   belongs to the earliest-started session, as in mining/10-operator_context.sql.
--   (1) weekly: invocations per ISO week (Monday start), runtime, channel, skill.
--   (2) corrections: correction_candidates loci (any detector, distinct message) in
--     the WINDOW (invocation, 3rd operator message after it], or to session end when
--     fewer follow. Per skill: invocations, candidates_after, candidates per
--     invocation, and per operator message in the window. (2b) is the baseline.
--     (2c) totals across skills: per-skill sums double-credit a candidate that sits in
--     several windows, so it gives the distinct candidate count beside the sum, how
--     many invocations overlap another window, and how many windows are unbounded
--     (run to session end, over half on a real lake).
--   (3) active: a skill is ACTIVE from its invocation until the next skill
--     invocation, the next operator message, or session end, whichever is first, the
--     defensible reading of "this turn's skill". Tool calls strictly after the
--     invocation and before the end count; errors and denials by skill.
--   Operator messages are operator_messages (typed, non-noise, non-copy). (2) and
--   (3) count model_tool and slash_command only.
-- SCOPE: non-sidechain rows only; is_meta rows never count as slash invocations.
--   pi records no tool calls and no skill tool; it appears only if its rows exist.
--   Reads the mined tables (operator_messages, correction_candidates): run just mine
--   first.
-- CAVEATS: windows of back-to-back skills overlap, so one candidate or error can
--   count for several skills (see 2c). A parallel tool call stamped with the
--   invocation's timestamp is outside (3). tool_reject candidates sit on tool-result
--   rows, not typed speech, and count in (2). opencode stamps in the build zone and
--   claude-code in UTC; comparisons stay within a session, so the mix never crosses.
-- Run: just sql -f mining/queries/skill_usage.sql

CREATE TEMP TABLE main_msg AS
  SELECT runtime, session_id, message_id, min(timestamp) AS ts
  FROM messages
  WHERE NOT is_sidechain
  GROUP BY runtime, session_id, message_id;

-- main-thread tool calls, one per (runtime, tool_use_id): the earliest-started session wins
CREATE TEMP TABLE tc_main AS
  SELECT t.runtime, t.session_id, t.tool_name, t.tool_use_id, t.outcome, t.arguments,
         coalesce(t.started_at, m.ts) AS ts
  FROM tool_calls t
  JOIN main_msg m ON m.runtime = t.runtime AND m.session_id = t.session_id AND m.message_id = t.message_id
  JOIN sessions s ON s.runtime = t.runtime AND s.session_id = t.session_id
  QUALIFY row_number() OVER (
            PARTITION BY t.runtime,
                         coalesce(t.tool_use_id, concat_ws('/', t.session_id, t.message_id, t.tool_name))
            ORDER BY s.started_at NULLS LAST, t.session_id) = 1;

CREATE TEMP TABLE inv_tool AS
  SELECT runtime, session_id, 'model_tool' AS invocation_channel,
         ltrim(coalesce(json_extract_string(arguments, '$.skill'),
                        json_extract_string(arguments, '$.name')), '/') AS skill,
         ts
  FROM tc_main
  WHERE tool_name IN ('Skill', 'skill') AND outcome = 'ok'
  UNION ALL
  SELECT runtime, session_id, 'skill_file_read',
         regexp_extract(arguments, '/skills/([^/"\\]+)/SKILL\.md', 1), ts
  FROM tc_main
  WHERE tool_name IN ('Read', 'read')
    AND regexp_matches(arguments, '/skills/[^/"\\]+/SKILL\.md');

-- typed operator rows, with the next typed operator row and the next skill expansion
CREATE TEMP TABLE typed AS
  SELECT runtime, session_id, message_id, timestamp AS ts, text,
         lead(timestamp) OVER (PARTITION BY runtime, session_id ORDER BY timestamp, message_id) AS next_typed_ts
  FROM messages
  WHERE role = 'user' AND origin = 'operator' AND NOT is_sidechain AND NOT is_meta;

CREATE TEMP TABLE expansion AS
  SELECT runtime, session_id, timestamp AS ts
  FROM messages
  WHERE is_meta AND NOT is_sidechain AND ltrim(text) LIKE 'Base directory for this skill:%';

CREATE TEMP TABLE slash AS
  SELECT t.runtime, t.session_id, t.message_id,
         regexp_extract(t.text, '<command-name>/?([^<]+)</command-name>', 1) AS skill, t.ts
  FROM typed t
  JOIN sessions s ON s.runtime = t.runtime AND s.session_id = t.session_id
  WHERE t.text LIKE '%<command-name>%'
    AND EXISTS (SELECT 1 FROM expansion e
                WHERE e.runtime = t.runtime AND e.session_id = t.session_id
                  AND e.ts >= t.ts AND e.ts < coalesce(t.next_typed_ts, TIMESTAMP 'infinity'))
  QUALIFY row_number() OVER (PARTITION BY t.runtime, t.message_id
                             ORDER BY s.started_at NULLS LAST, t.session_id) = 1;

CREATE TEMP TABLE inv AS
  SELECT * FROM inv_tool WHERE skill <> ''
  UNION ALL
  SELECT runtime, session_id, 'slash_command', skill, ts FROM slash WHERE skill <> '';

CREATE TEMP TABLE fired AS
  SELECT row_number() OVER () AS inv_id, runtime, session_id, invocation_channel, skill, ts
  FROM inv
  WHERE invocation_channel <> 'skill_file_read' AND ts IS NOT NULL;

CREATE TEMP TABLE ops AS
  SELECT runtime, session_id, ts,
         row_number() OVER (PARTITION BY runtime, session_id ORDER BY ts, message_uuid) AS n
  FROM operator_messages;

-- first operator message after each invocation, and the 3rd, bound the windows
CREATE TEMP TABLE bounds AS
  SELECT f.inv_id, f.runtime, f.session_id, f.skill, f.ts,
         o1.ts AS next_op_ts,
         o3.ts AS third_op_ts,
         (SELECT min(g.ts) FROM fired g
           WHERE g.runtime = f.runtime AND g.session_id = f.session_id AND g.ts > f.ts) AS next_skill_ts
  FROM fired f
  ASOF LEFT JOIN ops o1 ON o1.runtime = f.runtime AND o1.session_id = f.session_id AND f.ts < o1.ts
  LEFT JOIN ops o3 ON o3.runtime = f.runtime AND o3.session_id = f.session_id
                  AND o3.n = o1.n + 2;

-- one row per (invocation, candidate message) inside the window
CREATE TEMP TABLE win_cand AS
  SELECT b.inv_id, c.runtime, c.session_id, c.message_uuid
  FROM bounds b
  JOIN correction_candidates c
    ON c.runtime = b.runtime AND c.session_id = b.session_id
   AND c.ts > b.ts AND c.ts <= coalesce(b.third_op_ts, b.ts + INTERVAL 100 YEAR)
  GROUP BY ALL;

CREATE TEMP TABLE after_inv AS
  SELECT b.inv_id, b.skill, b.runtime, b.third_op_ts IS NULL AS unbounded,
         (SELECT count(*) FROM win_cand w WHERE w.inv_id = b.inv_id) AS candidates,
         (SELECT count(*) FROM ops o
           WHERE o.runtime = b.runtime AND o.session_id = b.session_id
             AND o.ts > b.ts AND o.ts <= coalesce(b.third_op_ts, b.ts + INTERVAL 100 YEAR)
         ) AS window_ops,
         EXISTS (SELECT 1 FROM fired g
                  WHERE g.runtime = b.runtime AND g.session_id = b.session_id
                    AND g.inv_id <> b.inv_id AND g.ts > b.ts
                    AND g.ts <= coalesce(b.third_op_ts, b.ts + INTERVAL 100 YEAR)) AS overlapping
  FROM bounds b;

CREATE TEMP TABLE tool_main AS
  SELECT runtime, session_id, tool_name, outcome, ts
  FROM tc_main
  WHERE session_id IN (SELECT session_id FROM fired)
    AND tool_name NOT IN ('Skill', 'skill');

CREATE TEMP TABLE active_inv AS
  SELECT b.inv_id, b.skill, b.runtime,
         count(t.ts)                                      AS tool_calls,
         count(*) FILTER (WHERE t.outcome = 'error')      AS errors,
         count(*) FILTER (WHERE t.outcome = 'denied')     AS denied
  FROM bounds b
  LEFT JOIN tool_main t
    ON t.runtime = b.runtime AND t.session_id = b.session_id AND t.ts > b.ts
   AND t.ts < least(coalesce(b.next_op_ts, TIMESTAMP 'infinity'),
                    coalesce(b.next_skill_ts, TIMESTAMP 'infinity'))
  GROUP BY b.inv_id, b.skill, b.runtime;

-- (1) invocations per ISO week, runtime, channel and skill
SELECT strftime(date_trunc('week', ts), '%G-W%V') AS iso_week, runtime, invocation_channel, skill,
       count(*) AS invocations
FROM inv
WHERE ts IS NOT NULL
GROUP BY ALL
ORDER BY iso_week, runtime, invocations DESC, skill, invocation_channel;

-- (2) correction candidates in the 3-operator-message window after an invocation
SELECT skill,
       string_agg(DISTINCT runtime, ',' ORDER BY runtime)           AS runtimes,
       count(*)                                                     AS invocations,
       sum(candidates)                                              AS candidates_after,
       round(sum(candidates) / count(*), 3)                         AS candidates_per_invocation,
       sum(window_ops)                                              AS window_operator_messages,
       round(sum(candidates) / nullif(sum(window_ops), 0), 3)       AS candidates_per_operator_message
FROM after_inv
GROUP BY skill
ORDER BY sum(candidates) DESC, count(*) DESC, skill;

-- (2c) windows across skills: the per-skill sum against the distinct candidates
SELECT (SELECT count(*) FROM after_inv)                              AS invocations,
       (SELECT sum(candidates) FROM after_inv)                       AS candidates_summed,
       (SELECT count(*) FROM (SELECT DISTINCT runtime, session_id, message_uuid FROM win_cand)) AS candidates_distinct,
       (SELECT count(*) FROM after_inv WHERE overlapping)               AS invocations_overlapping,
       (SELECT count(*) FROM after_inv WHERE unbounded)              AS windows_unbounded;

-- (2b) baseline: candidate loci per operator message with no skill filter
SELECT o.runtime,
       count(*)                                                     AS operator_messages,
       count(*) FILTER (WHERE o.flagged)                            AS flagged,
       round(count(*) FILTER (WHERE o.flagged) / count(*), 3)       AS flagged_share
FROM operator_messages o
GROUP BY o.runtime
ORDER BY o.runtime;

-- (3) tool errors and denials while a skill is active
SELECT skill,
       string_agg(DISTINCT runtime, ',' ORDER BY runtime)           AS runtimes,
       count(*)                                                     AS invocations,
       sum(tool_calls)                                              AS tool_calls,
       sum(errors)                                                  AS errors,
       sum(denied)                                                  AS denied,
       round((sum(errors) + sum(denied)) / count(*), 3)             AS fails_per_invocation,
       round((sum(errors) + sum(denied)) / nullif(sum(tool_calls), 0), 3) AS fail_share
FROM active_inv
GROUP BY skill
ORDER BY sum(errors) + sum(denied) DESC, count(*) DESC, skill;
