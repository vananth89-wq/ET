-- mig 496: Backfill short ref_id codes for RESIGNATION_REASON and TERMINATION_REASON
-- R001–R008 for resignation, T001–T011 for termination.
-- Also fixes the seed in mig 484 for fresh installs going forward.

DO $$
DECLARE
  v_pl_id uuid;
BEGIN

  -- ── RESIGNATION_REASON ──────────────────────────────────────────────────
  SELECT id INTO v_pl_id FROM picklists WHERE picklist_id = 'RESIGNATION_REASON';

  IF v_pl_id IS NOT NULL THEN
    UPDATE picklist_values SET ref_id = 'R001' WHERE picklist_id = v_pl_id AND value = 'Better Opportunity';
    UPDATE picklist_values SET ref_id = 'R002' WHERE picklist_id = v_pl_id AND value = 'Higher Studies';
    UPDATE picklist_values SET ref_id = 'R003' WHERE picklist_id = v_pl_id AND value = 'Relocation';
    UPDATE picklist_values SET ref_id = 'R004' WHERE picklist_id = v_pl_id AND value = 'Personal Reasons';
    UPDATE picklist_values SET ref_id = 'R005' WHERE picklist_id = v_pl_id AND value = 'Family Commitments';
    UPDATE picklist_values SET ref_id = 'R006' WHERE picklist_id = v_pl_id AND value = 'Health Reasons';
    UPDATE picklist_values SET ref_id = 'R007' WHERE picklist_id = v_pl_id AND value = 'Retirement';
    UPDATE picklist_values SET ref_id = 'R008' WHERE picklist_id = v_pl_id AND value = 'Other';
  END IF;

  -- ── TERMINATION_REASON ──────────────────────────────────────────────────
  SELECT id INTO v_pl_id FROM picklists WHERE picklist_id = 'TERMINATION_REASON';

  IF v_pl_id IS NOT NULL THEN
    UPDATE picklist_values SET ref_id = 'T001' WHERE picklist_id = v_pl_id AND value = 'Performance';
    UPDATE picklist_values SET ref_id = 'T002' WHERE picklist_id = v_pl_id AND value = 'Misconduct';
    UPDATE picklist_values SET ref_id = 'T003' WHERE picklist_id = v_pl_id AND value = 'Policy Violation';
    UPDATE picklist_values SET ref_id = 'T004' WHERE picklist_id = v_pl_id AND value = 'Probation Failure';
    UPDATE picklist_values SET ref_id = 'T005' WHERE picklist_id = v_pl_id AND value = 'Absconding';
    UPDATE picklist_values SET ref_id = 'T006' WHERE picklist_id = v_pl_id AND value = 'Position Redundancy';
    UPDATE picklist_values SET ref_id = 'T007' WHERE picklist_id = v_pl_id AND value = 'Organisation Restructuring';
    UPDATE picklist_values SET ref_id = 'T008' WHERE picklist_id = v_pl_id AND value = 'End of Contract';
    UPDATE picklist_values SET ref_id = 'T009' WHERE picklist_id = v_pl_id AND value = 'Retirement';
    UPDATE picklist_values SET ref_id = 'T010' WHERE picklist_id = v_pl_id AND value = 'Death';
    UPDATE picklist_values SET ref_id = 'T011' WHERE picklist_id = v_pl_id AND value = 'Other';
  END IF;

END $$;

COMMENT ON TABLE picklist_values IS
  'Mig 496: RESIGNATION_REASON ref_ids → R001–R008; TERMINATION_REASON → T001–T011.';
