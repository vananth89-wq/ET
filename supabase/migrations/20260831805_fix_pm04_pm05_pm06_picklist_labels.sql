-- Fix mig 803: used p.code instead of p.picklist_id so the insert matched
-- nothing and PM04-PM06 have no picklist labels. This upserts the correct rows.

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
where p.picklist_id = 'JOB_RELATIONSHIP_TYPE'
on conflict (picklist_id, ref_id) do update
  set value  = excluded.value,
      active = true;
