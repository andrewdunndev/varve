-- The lake's columns are the columns sql/record.sql describes, no more and no
-- fewer. A <rt>_* column (cc_, pi_, oc_, or the runtime's own name) and agent
-- are extensions and stay exempt. A table the lake does not hold yet is skipped.
CREATE VIEW IF NOT EXISTS runtimes AS SELECT NULL::VARCHAR AS name WHERE false;
WITH have AS (
  SELECT table_name, column_name
  FROM information_schema.columns
  WHERE table_schema = 'main' AND table_name IN (SELECT DISTINCT table_name FROM record)
),
ext AS (
  SELECT lower(name) AS prefix FROM runtimes
  UNION SELECT 'cc' UNION SELECT 'pi' UNION SELECT 'oc'
)
SELECT h.table_name || '.' || h.column_name || ' is not in sql/record.sql; add its meaning there, or name it <rt>_' || h.column_name AS action
FROM have h
WHERE h.column_name <> 'agent'
  AND NOT EXISTS (SELECT 1 FROM record r WHERE r.table_name = h.table_name AND r.column_name = h.column_name)
  AND NOT (contains(h.column_name, '_') AND split_part(h.column_name, '_', 1) IN (SELECT prefix FROM ext))
UNION ALL
SELECT r.table_name || '.' || r.column_name || ' is in sql/record.sql but missing from the lake; run just build'
FROM record r
WHERE r.table_name IN (SELECT table_name FROM have)
  AND NOT EXISTS (SELECT 1 FROM have h WHERE h.table_name = r.table_name AND h.column_name = r.column_name)
ORDER BY 1;
