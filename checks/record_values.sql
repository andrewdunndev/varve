-- The closed sets of sql/record.sql hold: origin and outcome take only the values
-- the record names. NULL is always allowed.
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS origin WHERE false;
CREATE VIEW IF NOT EXISTS tool_calls AS SELECT NULL::VARCHAR AS outcome WHERE false;
SELECT 'messages.origin has ' || n || ' row(s) with value ' || v || '; fix the adapter that wrote them' AS action
FROM (SELECT origin AS v, count(*) AS n FROM messages
      WHERE origin NOT IN ('operator', 'tool_result', 'model') GROUP BY origin)
UNION ALL
SELECT 'tool_calls.outcome has ' || n || ' row(s) with value ' || v || '; fix the adapter that wrote them'
FROM (SELECT outcome AS v, count(*) AS n FROM tool_calls
      WHERE outcome NOT IN ('ok', 'error', 'denied', 'cancelled', 'running') GROUP BY outcome)
ORDER BY 1;
