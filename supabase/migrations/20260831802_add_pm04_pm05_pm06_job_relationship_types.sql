-- Add PM04, PM05, PM06 to the JOB_RELATIONSHIP_TYPE picklist.
-- These extend the existing PM01–PM03 slots to support employees
-- assigned to more than three projects simultaneously.

insert into picklist_values (picklist_id, value, ref_id, active)
select
  p.id,
  v.label,
  v.ref_id,
  true
from picklists p
cross join (
  values
    ('Project Manager 4', 'PM04'),
    ('Project Manager 5', 'PM05'),
    ('Project Manager 6', 'PM06')
) as v(label, ref_id)
where p.code = 'JOB_RELATIONSHIP_TYPE'
  -- skip if already present (safe to re-run)
  and not exists (
    select 1 from picklist_values pv
    where pv.picklist_id = p.id
      and pv.ref_id = v.ref_id
  );
