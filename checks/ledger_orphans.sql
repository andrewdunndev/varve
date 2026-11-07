-- Every adjudication keys a mined candidate and a message that still exist.
CREATE VIEW IF NOT EXISTS adjudications AS SELECT NULL::JSON AS j WHERE false;
CREATE VIEW IF NOT EXISTS correction_candidates AS SELECT NULL::VARCHAR AS candidate_id WHERE false;
CREATE VIEW IF NOT EXISTS messages AS SELECT NULL::VARCHAR AS message_id WHERE false;
WITH l AS (
  SELECT j ->> 'candidate_id' AS candidate_id, j ->> 'message_uuid' AS message_uuid FROM adjudications
)
SELECT 'adjudicated candidate ' || candidate_id || ' is not among the mined candidates; restore the mirror files it came from, or correct the ledger' AS action
FROM l
WHERE candidate_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM correction_candidates c WHERE c.candidate_id = l.candidate_id)
UNION ALL
SELECT 'adjudicated message ' || message_uuid || ' is not in the lake; restore the mirror files it came from, or correct the ledger'
FROM l
WHERE message_uuid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.message_id = l.message_uuid)
ORDER BY 1;
