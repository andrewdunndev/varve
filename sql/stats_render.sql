-- `just stats` text renderer over the stats_window / stats_days / stats_totals temp
-- tables that queries/stats_year.sql builds in the same session (ADR-0007).
CREATE OR REPLACE TEMP MACRO stats_compact(x) AS
  CASE WHEN x < 1000 THEN printf('%d', x::bigint)
       WHEN x < 999950 THEN printf('%.1fk', x / 1e3)
       WHEN x < 999950000 THEN printf('%.1fm', x / 1e6)
       ELSE printf('%.1fb', x / 1e9) END;

CREATE OR REPLACE TEMP MACRO stats_money(x) AS
  '$' || CASE WHEN x < 1000 THEN printf('%.2f', x)
              WHEN x < 999995 THEN printf('%.2fk', x / 1e3)
              ELSE printf('%.2fm', x / 1e6) END;

CREATE OR REPLACE TEMP MACRO stats_count(x, noun) AS
  stats_compact(x) || ' ' || noun || CASE WHEN x = 1 THEN '' ELSE 's' END;

WITH t AS (SELECT * FROM stats_totals),
frame AS (
  SELECT t.*,
         date_trunc('week', first_day)::date AS week0,
         CASE WHEN year > year(today) THEN make_date(year, 12, 31) ELSE last_day END AS grid_end
  FROM t
),
cols AS (
  SELECT unnest(range(0, date_diff('day', week0, grid_end) // 7 + 1)) AS col FROM frame
),
weekdays AS (
  SELECT unnest(range(0, 7)) AS dow, unnest(['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su']) AS label
),
cells AS (
  SELECT w.dow, w.label, c.col,
         CASE WHEN d.day IS NULL THEN ' '
              ELSE ['·', '░', '▒', '▓', '█'][d.level + 1] END AS glyph
  FROM frame f CROSS JOIN weekdays w CROSS JOIN cols c
  LEFT JOIN stats_days d ON d.day = f.week0 + (c.col * 7 + w.dow)::int
),
months AS (
  SELECT strftime(m, '%b') AS label, date_diff('day', f.week0, m::date) // 7 AS col
  FROM frame f, (SELECT unnest(generate_series(make_date(f2.year, 1, 1), f2.grid_end, INTERVAL 1 MONTH)) AS m FROM frame f2)
),
header AS (
  SELECT rtrim(string_agg(coalesce(substr(m.label, p.col - m.col + 1, 1), ' '), '' ORDER BY p.col)) AS line
  FROM (SELECT unnest(range(0, (SELECT max(col) FROM cols) + 4)) AS col) p
  LEFT JOIN months m ON p.col BETWEEN m.col AND m.col + 2
),
lines AS (
  SELECT 0 AS ord,
         'varve stats · ' || year
         || CASE WHEN year = year(today) AND last_day < make_date(year, 12, 31) THEN ' so far' ELSE '' END
         || ' · ' || CASE runtime WHEN 'all' THEN 'all runtimes' ELSE runtime END AS line
  FROM t
  UNION ALL SELECT 1, ''
  UNION ALL SELECT 2, 'activity' || CASE WHEN metric = 'prompts' THEN '' ELSE ' · ' || metric END FROM t
  UNION ALL SELECT 3, '   ' || line FROM header
  UNION ALL
  SELECT 4 + dow, rtrim(label || ' ' || string_agg(glyph, '' ORDER BY col)) FROM cells GROUP BY dow, label
  UNION ALL SELECT 11, '   less ·░▒▓█ more'
  UNION ALL SELECT 12, ''
  UNION ALL SELECT 13, stats_count(sessions, 'session') || ' · ' || stats_count(subagents, 'subagent') FROM t
  UNION ALL
  SELECT 14, stats_count(prompts, 'prompt') || ' · ' || stats_count(steps, 'step') || ' · '
             || stats_compact(tokens) || ' tokens · ' || stats_money(cost_usd) FROM t
  UNION ALL
  SELECT 15, coalesce(printf('%.1f%%', tool_success_pct), 'n/a') || ' tool success · '
             || stats_count(active_days, 'active day') || ' · best streak ' || stats_count(best_streak, 'day')
  FROM t
)
SELECT line FROM lines ORDER BY ord;
