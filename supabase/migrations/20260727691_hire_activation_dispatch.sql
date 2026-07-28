-- =============================================================================
-- Migration 691 — Server-side hire activation dispatch + audit + retry cron
--
-- PROBLEM
-- ═══════
-- Employee activation (auth.users creation + password-recovery email) is
-- currently fired from the frontend after workflow approval. If the browser
-- tab closes, network glitches, or the frontend SELECT swallows an error,
-- activation is silently skipped. Hires end up "Active" in the DB but with
-- no auth account and no email — recoverable only via manual admin invite.
--
-- SOLUTION (three layers)
-- ═══════════════════════
-- 1. Audit table  `hire_activation_dispatches`
--    Every dispatch attempt is logged with instance_id, record_id, request_id
--    (pg_net), timestamps, and outcome. Enables observability + retry logic.
--
-- 2. AFTER UPDATE trigger `trg_dispatch_hire_activation`
--    Fires when workflow_instances.status transitions to 'approved' for
--    module_code='employee_hire'. Calls the activate-employee Edge Function
--    via pg_net with x-service-role header. Fire-and-forget.
--
-- 3. pg_cron retry job `hire_activation_retry`
--    Every 5 min, scans get_stuck_hire_activations() and re-fires the
--    Edge Function for any hire that is workflow-approved but has no
--    linked auth.users row yet. Belt-and-suspenders for transient
--    pg_net / Edge Function failures.
--
-- Combined with the frontend Edge Function call (kept for UX responsiveness),
-- this gives us defense in depth:
--   Frontend call  → instant user feedback
--   DB trigger     → guaranteed dispatch on ANY approval path
--   Cron retry     → recovers from transient failures
--
-- IDEMPOTENT: all objects use CREATE OR REPLACE / IF NOT EXISTS.
-- =============================================================================


-- ── 1. Audit table ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.hire_activation_dispatches (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id   uuid,
  record_id     uuid        NOT NULL,
  source        text        NOT NULL CHECK (source IN ('trigger', 'cron_retry', 'manual')),
  request_id    bigint,       -- pg_net request id (nullable if dispatch never issued)
  requested_at  timestamptz NOT NULL DEFAULT now(),
  http_status   int,          -- populated later by observer if needed
  error_message text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hire_act_dispatch_record ON public.hire_activation_dispatches (record_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_hire_act_dispatch_time   ON public.hire_activation_dispatches (requested_at DESC);

ALTER TABLE public.hire_activation_dispatches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hire_act_dispatch_admin_select ON public.hire_activation_dispatches;
CREATE POLICY hire_act_dispatch_admin_select
  ON public.hire_activation_dispatches
  FOR SELECT
  USING (has_role('admin') OR is_super_admin());

COMMENT ON TABLE public.hire_activation_dispatches IS
  'Audit log of every activate-employee Edge Function dispatch. '
  'source: trigger (on approval), cron_retry (from pg_cron), manual (admin). '
  'Mig 691.';


-- ── 2. Helper: dispatch to Edge Function ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.dispatch_hire_activation(
  p_record_id   uuid,
  p_instance_id uuid,
  p_source      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_url        text;
  v_secret     text;
  v_request_id bigint;
BEGIN
  SELECT value INTO v_url    FROM app_config WHERE key = 'supabase_functions_url';
  SELECT value INTO v_secret FROM app_config WHERE key = 'webhook_secret';

  IF v_url IS NULL OR v_url = '' THEN
    INSERT INTO public.hire_activation_dispatches (record_id, instance_id, source, error_message)
    VALUES (p_record_id, p_instance_id, p_source, 'supabase_functions_url not configured in app_config');
    RAISE WARNING 'dispatch_hire_activation: supabase_functions_url not set';
    RETURN;
  END IF;

  BEGIN
    SELECT net.http_post(
      url     := v_url || '/activate-employee',
      headers := jsonb_build_object(
        'Content-Type',     'application/json',
        'x-service-role',   'true',
        'x-webhook-secret', COALESCE(v_secret, '')
      ),
      body    := jsonb_build_object('employee_id', p_record_id),
      timeout_milliseconds := 8000
    ) INTO v_request_id;

    INSERT INTO public.hire_activation_dispatches (record_id, instance_id, source, request_id)
    VALUES (p_record_id, p_instance_id, p_source, v_request_id);

  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.hire_activation_dispatches (record_id, instance_id, source, error_message)
    VALUES (p_record_id, p_instance_id, p_source, SQLERRM);
    RAISE WARNING 'dispatch_hire_activation failed: %', SQLERRM;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.dispatch_hire_activation(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dispatch_hire_activation(uuid, uuid, text) TO postgres;

COMMENT ON FUNCTION public.dispatch_hire_activation(uuid, uuid, text) IS
  'Sends a POST to the activate-employee Edge Function via pg_net. '
  'Logs each attempt to hire_activation_dispatches. Fire-and-forget. Mig 691.';


-- ── 3. Trigger on workflow_instances ────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.trg_dispatch_hire_activation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only fire on employee_hire workflow transitioning INTO 'approved'
  IF NEW.module_code <> 'employee_hire' THEN RETURN NEW; END IF;
  IF NEW.status      <> 'approved'      THEN RETURN NEW; END IF;
  IF OLD.status       = 'approved'      THEN RETURN NEW; END IF;

  PERFORM public.dispatch_hire_activation(NEW.record_id, NEW.id, 'trigger');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS after_wf_instance_hire_approved ON public.workflow_instances;
CREATE TRIGGER after_wf_instance_hire_approved
  AFTER UPDATE OF status ON public.workflow_instances
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_dispatch_hire_activation();

COMMENT ON FUNCTION public.trg_dispatch_hire_activation() IS
  'Fires activate-employee EF when a hire workflow becomes approved. Mig 691.';


-- ── 4. pg_cron retry — every 5 min ──────────────────────────────────────────

-- Remove previous registration (idempotent)
SELECT cron.unschedule('hire_activation_retry')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hire_activation_retry');

SELECT cron.schedule(
  'hire_activation_retry',
  '*/5 * * * *',
  $cron$
    DO $$
    DECLARE
      rec RECORD;
    BEGIN
      -- get_stuck_hire_activations() returns hires that are workflow-approved
      -- but whose auth user is missing / not linked (mig 576).
      FOR rec IN SELECT * FROM public.get_stuck_hire_activations() LOOP
        -- Skip if we already dispatched in the last 10 min (avoid loops)
        IF EXISTS (
          SELECT 1 FROM public.hire_activation_dispatches
          WHERE record_id    = rec.employee_id
            AND requested_at > now() - interval '10 minutes'
        ) THEN CONTINUE; END IF;

        PERFORM public.dispatch_hire_activation(rec.employee_id, rec.instance_id, 'cron_retry');
      END LOOP;
    END$$;
  $cron$
);


-- ── 5. Verification ─────────────────────────────────────────────────────────

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'after_wf_instance_hire_approved') THEN
    RAISE EXCEPTION 'ABORT: after_wf_instance_hire_approved trigger not installed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'dispatch_hire_activation') THEN
    RAISE EXCEPTION 'ABORT: dispatch_hire_activation function missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'hire_activation_retry') THEN
    RAISE EXCEPTION 'ABORT: hire_activation_retry cron job not scheduled';
  END IF;
  RAISE NOTICE 'Migration 691 verified: trigger + audit table + retry cron installed.';
END $$;
