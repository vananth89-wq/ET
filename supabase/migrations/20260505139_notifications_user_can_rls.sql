-- =============================================================================
-- Migration 139: Upgrade notifications & notification_attempts RLS
--
-- CURRENT STATE
-- ─────────────
-- notifications (migration 011 — already cleaned up):
--   notifications_select  → profile_id = auth.uid()  (own only — good)
--   notifications_update  → profile_id = auth.uid()  (mark-as-read — good)
--   No INSERT policy — SECURITY DEFINER trigger inserts rows; deny-by-default.
--   No DELETE policy — notifications are not user-deletable.
--
-- notification_attempts (migration 052):
--   notif_attempts_admin_select → has_role('admin') OR has_permission('workflow.admin')
--
-- CHANGES
-- ───────
-- notifications_select:
--   Add OR user_can('wf_notifications', 'view', NULL) so Notification Admins
--   can monitor delivery status across all users in the UI.
--   Self-access (profile_id = auth.uid()) is preserved — ESS users still see
--   only their own inbox without needing any matrix grant.
--
-- notifications_update:
--   Unchanged — only the recipient should mark their own notification as read.
--   Admin monitoring is read-only; no admin update path is needed.
--
-- notif_attempts_admin_select:
--   Replaces has_role + has_permission with user_can('wf_notifications','view').
--   Attempts are written by SECURITY DEFINER delivery trigger only.
-- =============================================================================


-- ── 1. notifications — add admin view path ────────────────────────────────────

DROP POLICY IF EXISTS notifications_select ON notifications;

CREATE POLICY notifications_select ON notifications FOR SELECT
  USING (
    profile_id = auth.uid()
    OR user_can('wf_notifications', 'view', NULL)
  );

-- notifications_update unchanged (profile_id = auth.uid() only)


-- ── 2. notification_attempts ──────────────────────────────────────────────────

DROP POLICY IF EXISTS notif_attempts_admin_select ON notification_attempts;

CREATE POLICY notif_attempts_admin_select ON notification_attempts FOR SELECT
  USING (user_can('wf_notifications', 'view', NULL));


-- ── Verification ──────────────────────────────────────────────────────────────

SELECT tablename, policyname, cmd
FROM pg_policies
WHERE tablename IN ('notifications', 'notification_attempts')
ORDER BY tablename, cmd, policyname;
