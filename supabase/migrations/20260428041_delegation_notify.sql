-- =============================================================================
-- Delegation notification RPC
--
-- Inserts a notification for the delegate when a new delegation is created.
-- Runs as SECURITY DEFINER so any authenticated user (not just admin) can
-- trigger it — the function validates the caller owns the delegation before
-- inserting, preventing abuse.
--
-- Called from the frontend immediately after INSERT INTO workflow_delegations.
-- =============================================================================

CREATE OR REPLACE FUNCTION notify_delegation_created(
  p_delegation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_del       RECORD;
  v_delegator_name text;
BEGIN
  -- Load the delegation row — caller must be the delegator or an admin
  SELECT
    d.delegator_id,
    d.delegate_id,
    d.from_date,
    d.to_date,
    t.name AS template_name
  INTO v_del
  FROM  workflow_delegations d
  LEFT  JOIN workflow_templates t ON t.id = d.template_id
  WHERE d.id = p_delegation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Delegation not found: %', p_delegation_id;
  END IF;

  -- Security check: caller must be the delegator or have admin role
  IF v_del.delegator_id != auth.uid() AND NOT has_role('admin') THEN
    RAISE EXCEPTION 'Permission denied: you do not own this delegation.';
  END IF;

  -- Resolve delegator display name
  SELECT e.name
  INTO   v_delegator_name
  FROM   profiles p
  JOIN   employees e ON e.id = p.employee_id
  WHERE  p.id = v_del.delegator_id;

  -- Insert notification for the delegate
  INSERT INTO notifications (profile_id, title, body, link)
  VALUES (
    v_del.delegate_id,
    'Approval tasks delegated to you',
    format(
      '%s has delegated their approval tasks to you from %s to %s%s.',
      COALESCE(v_delegator_name, 'A colleague'),
      to_char(v_del.from_date, 'DD Mon YYYY'),
      to_char(v_del.to_date,   'DD Mon YYYY'),
      CASE
        WHEN v_del.template_name IS NOT NULL
          THEN ' for ' || v_del.template_name
        ELSE ' (all approval types)'
      END
    ),
    '/workflow/delegations'
  );
END;
$$;

COMMENT ON FUNCTION notify_delegation_created(uuid) IS
  'Inserts a notification for the delegate when a delegation is created. '
  'Caller must be the delegator or an admin. SECURITY DEFINER to bypass '
  'the notifications INSERT RLS which restricts direct inserts to admins only.';


-- ── Verification ──────────────────────────────────────────────────────────────
SELECT proname FROM pg_proc WHERE proname = 'notify_delegation_created';
