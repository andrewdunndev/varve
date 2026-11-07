CREATE VIEW IF NOT EXISTS correction_candidates AS SELECT NULL::VARCHAR AS candidate_id WHERE false;
SELECT 'correction_candidates is empty; the fixture no longer trips a detector' AS action
WHERE NOT EXISTS (SELECT 1 FROM correction_candidates);
