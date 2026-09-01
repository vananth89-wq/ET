-- =============================================================================
-- READ-ONLY AUDIT — support hours recorded against a project the employee was
-- actually allocated to on that day.
--
-- Nothing is written. Run it in the Supabase SQL editor against Dev.
--
-- WHY IT MATTERS: help given to a project is deliberately kept out of that
-- project's utilisation, burn and cost (mig 801). If the employee was on the
-- project that day, those are ordinary project hours and the project should be
-- carrying them -- so every row below is hours that quietly left a project's
-- numbers. This is the check that says whether that is theoretical or already
-- in your figures, and it is the audit that has to come before any hard
-- server-side refusal.
-- =============================================================================

-- ── 1. The headline ──────────────────────────────────────────────────────────
SELECT
  count(*)                                        AS entries_affected,
  count(DISTINCT h.employee_id)                   AS employees,
  count(DISTINCT en.related_project_id)           AS projects,
  round(sum(en.hours_minutes) / 60.0, 1)          AS hours,
  min(en.entry_date)                              AS earliest,
  max(en.entry_date)                              AS latest
FROM   timesheet_entries en
JOIN   timesheet_headers h ON h.id = en.header_id
WHERE  en.related_project_id IS NOT NULL
  AND  EXISTS (
         SELECT 1 FROM project_members pm
         WHERE  pm.employee_id     = h.employee_id
           AND  pm.project_id      = en.related_project_id
           AND  pm.effective_from <= en.entry_date
           AND  (pm.effective_to IS NULL OR pm.effective_to >= en.entry_date));

-- ── 2. For scale: ALL support hours, however they were recorded ──────────────
SELECT
  count(*)                               AS all_support_entries,
  round(sum(en.hours_minutes) / 60.0, 1) AS all_support_hours
FROM   timesheet_entries en
WHERE  en.related_project_id IS NOT NULL;

-- ── 3. Who and what, so a decision can be made per row ───────────────────────
SELECT
  emp.name                               AS employee,
  p.name                                 AS helped_project,
  tt.name                                AS time_type,
  count(*)                               AS entries,
  round(sum(en.hours_minutes) / 60.0, 1) AS hours,
  min(en.entry_date)                     AS first_date,
  max(en.entry_date)                     AS last_date
FROM   timesheet_entries en
JOIN   timesheet_headers h   ON h.id  = en.header_id
JOIN   employees        emp  ON emp.id = h.employee_id
JOIN   projects         p    ON p.id  = en.related_project_id
LEFT   JOIN time_types  tt   ON tt.id = en.time_type_id
WHERE  en.related_project_id IS NOT NULL
  AND  EXISTS (
         SELECT 1 FROM project_members pm
         WHERE  pm.employee_id     = h.employee_id
           AND  pm.project_id      = en.related_project_id
           AND  pm.effective_from <= en.entry_date
           AND  (pm.effective_to IS NULL OR pm.effective_to >= en.entry_date))
GROUP  BY emp.name, p.name, tt.name
ORDER  BY hours DESC, employee;
