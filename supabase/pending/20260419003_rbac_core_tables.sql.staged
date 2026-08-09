-- ═══════════════════════════════════════════════════════════════════════════
-- Migration 20260419003: the RBAC core tables the history never created.
--
-- WHY THIS EXISTS
--   Every environment was built by copying an existing database, and that
--   original copy already contained tables created by hand in SQL. Five of
--   them sit at the centre of the permission engine:
--
--       modules · permissions · roles · user_roles · role_permissions
--
--   No migration in this repository has ever created them. They exist
--   everywhere only because they were carried along in the copy. Replaying the
--   history into an empty database therefore fails at 20260422002 with
--   `relation "roles" does not exist`, and ~113 further failures cascade from
--   that single hole.
--
--   This migration writes down what was in the copy, so the files finally
--   describe the database and a fresh environment can be built from them.
--
-- DATE PLACEMENT IS DELIBERATE
--   Numbered 20260419003 — immediately after 20260419001_initial_schema (which
--   creates `profiles`, referenced below) and well before the first migration
--   that needs these tables. A migration numbered for today would run LAST and
--   fix nothing: the failures happen hundreds of files earlier.
--
--   `supabase db push --include-all` applies out-of-order versions, so this
--   still lands on environments that are already ahead of it.
--
-- IT IS A NO-OP ON EVERY EXISTING ENVIRONMENT
--   CREATE TABLE IF NOT EXISTS, guarded constraints, CREATE INDEX IF NOT
--   EXISTS. Nothing here drops, alters or seeds. The shapes are taken verbatim
--   from Dev on 2026-08-09. Later migrations that add columns to these tables
--   all use ADD COLUMN IF NOT EXISTS, so they remain no-ops too.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Helper: add a constraint only if that name is free ─────────────────────
-- ALTER TABLE ... ADD CONSTRAINT has no IF NOT EXISTS.
CREATE OR REPLACE FUNCTION pg_temp.add_constraint_if_absent(p_table text, p_name text, p_def text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = p_name) THEN
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I %s', p_table, p_name, p_def);
  END IF;
END;
$$;

-- ── Helper: remember which tables existed BEFORE this migration ────────────
-- ENABLE ROW LEVEL SECURITY is the one statement here that is not purely
-- additive: re-enabling it on a table where someone deliberately turned it OFF
-- would start hiding rows from the application. So RLS is only ever switched on
-- for a table this migration actually creates. On any environment that already
-- has these tables, their RLS setting is left exactly as it is.
CREATE TEMP TABLE _pre_existing AS
SELECT c.relname::text AS tbl
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public'
   AND c.relname IN ('modules','permissions','roles','user_roles','role_permissions');

CREATE OR REPLACE FUNCTION pg_temp.enable_rls_if_new(p_table text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM _pre_existing WHERE tbl = p_table) THEN
    RAISE NOTICE 'Migration 20260419003: % already existed — leaving its RLS setting untouched.', p_table;
  ELSE
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', p_table);
  END IF;
END;
$$;

-- ── 1. modules ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.modules (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  code        text NOT NULL,
  name        text NOT NULL,
  active      boolean DEFAULT true,
  sort_order  integer DEFAULT 0,
  created_at  timestamp with time zone DEFAULT now(),
  updated_at  timestamp with time zone DEFAULT now()
);
SELECT pg_temp.add_constraint_if_absent('modules', 'modules_pkey',     'PRIMARY KEY (id)');
SELECT pg_temp.add_constraint_if_absent('modules', 'modules_code_key', 'UNIQUE (code)');
CREATE INDEX IF NOT EXISTS idx_module_code2 ON public.modules USING btree (code);
SELECT pg_temp.enable_rls_if_new('modules');

-- ── 2. permissions ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.permissions (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  module_id   uuid,
  code        text NOT NULL,
  name        text NOT NULL,
  description text,
  created_at  timestamp with time zone DEFAULT now(),
  sort_order  integer DEFAULT 999 NOT NULL,
  action      text
);
SELECT pg_temp.add_constraint_if_absent('permissions', 'permissions_pkey',     'PRIMARY KEY (id)');
SELECT pg_temp.add_constraint_if_absent('permissions', 'permissions_code_key', 'UNIQUE (code)');
SELECT pg_temp.add_constraint_if_absent('permissions', 'permissions_action_check',
  $c$CHECK ((action = ANY (ARRAY['view'::text, 'create'::text, 'edit'::text, 'delete'::text,
                                 'history'::text, 'lookup'::text, 'view_all_pending'::text,
                                 'edit_all_pending'::text, 'bulk_import'::text, 'bulk_export'::text,
                                 'view_inactive'::text, 'reassign'::text, 'reset'::text])))$c$);
SELECT pg_temp.add_constraint_if_absent('permissions', 'permissions_module_id_fkey',
  'FOREIGN KEY (module_id) REFERENCES public.modules(id) ON DELETE RESTRICT');
CREATE INDEX IF NOT EXISTS idx_perm_module_action
  ON public.permissions USING btree (module_id, action) WHERE (action IS NOT NULL);
SELECT pg_temp.enable_rls_if_new('permissions');

-- ── 3. roles ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.roles (
  id          uuid DEFAULT gen_random_uuid() NOT NULL,
  code        text NOT NULL,
  name        text NOT NULL,
  description text,
  is_system   boolean DEFAULT false,
  created_at  timestamp with time zone DEFAULT now(),
  updated_at  timestamp with time zone DEFAULT now(),
  role_type   text DEFAULT 'custom'::text NOT NULL,
  active      boolean DEFAULT true NOT NULL,
  sort_order  integer DEFAULT 99 NOT NULL,
  editable    boolean DEFAULT true NOT NULL
);
SELECT pg_temp.add_constraint_if_absent('roles', 'roles_pkey',     'PRIMARY KEY (id)');
SELECT pg_temp.add_constraint_if_absent('roles', 'roles_code_key', 'UNIQUE (code)');
SELECT pg_temp.add_constraint_if_absent('roles', 'roles_role_type_check',
  $c$CHECK ((role_type = ANY (ARRAY['system'::text, 'custom'::text, 'protected'::text])))$c$);
SELECT pg_temp.enable_rls_if_new('roles');

-- ── 4. user_roles ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_roles (
  id                uuid DEFAULT gen_random_uuid() NOT NULL,
  profile_id        uuid,
  role_id           uuid,
  granted_by        uuid,
  granted_at        timestamp with time zone DEFAULT now(),
  expires_at        timestamp with time zone,
  is_active         boolean DEFAULT true NOT NULL,
  updated_at        timestamp with time zone DEFAULT now() NOT NULL,
  assignment_source text DEFAULT 'manual'::text NOT NULL
);
SELECT pg_temp.add_constraint_if_absent('user_roles', 'user_roles_pkey', 'PRIMARY KEY (id)');
SELECT pg_temp.add_constraint_if_absent('user_roles', 'user_roles_profile_id_role_id_key',
  'UNIQUE (profile_id, role_id)');
SELECT pg_temp.add_constraint_if_absent('user_roles', 'user_roles_assignment_source_check',
  $c$CHECK ((assignment_source = ANY (ARRAY['manual'::text, 'system'::text, 'invite'::text,
                                            'auto'::text, 'reconcile'::text, 'backfill'::text,
                                            'sync_job'::text, 'system_reactivation'::text])))$c$);
SELECT pg_temp.add_constraint_if_absent('user_roles', 'user_roles_role_id_fkey',
  'FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE');
SELECT pg_temp.add_constraint_if_absent('user_roles', 'user_roles_profile_id_fkey',
  'FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE');
SELECT pg_temp.add_constraint_if_absent('user_roles', 'user_roles_granted_by_fkey',
  'FOREIGN KEY (granted_by) REFERENCES public.profiles(id)');
CREATE INDEX IF NOT EXISTS idx_user_roles_expires_at
  ON public.user_roles USING btree (expires_at) WHERE (expires_at IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_user_roles_profile_active2
  ON public.user_roles USING btree (profile_id) WHERE (is_active = true);
CREATE INDEX IF NOT EXISTS idx_user_roles_profile_active
  ON public.user_roles USING btree (profile_id, role_id) WHERE (is_active = true);
CREATE INDEX IF NOT EXISTS idx_user_roles_profile_id
  ON public.user_roles USING btree (profile_id);
SELECT pg_temp.enable_rls_if_new('user_roles');

-- ── 5. role_permissions — GONE TODAY, BUT NEEDED IN THE MIDDLE ─────────────
-- This one is different. It was hand-made like the others, used by 47
-- migrations, and then deliberately DROPPED by 20260506146. It does not exist
-- on Dev any more, which is correct.
--
-- A replay from zero still needs it: those 47 migrations run long before 146.
-- But recreating it on an environment that has already passed 146 would
-- resurrect a table someone deliberately removed.
--
-- So: create it only where 146 has not run yet. On a fresh replay the CLI's
-- ledger does not exist at all, so the table is created and 146 later drops it,
-- exactly as history intended.
--
-- Columns are the base shape only. target_group_id (mig 082) and
-- permission_set_id (mig 106) are added later with ADD COLUMN IF NOT EXISTS.
DO $$
DECLARE v_already_dropped boolean := false;
BEGIN
  IF to_regclass('supabase_migrations.schema_migrations') IS NOT NULL THEN
    EXECUTE $q$ SELECT EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations
                                WHERE version = '20260506146') $q$
      INTO v_already_dropped;
  END IF;

  IF v_already_dropped THEN
    RAISE NOTICE 'Migration 20260419003: skipping role_permissions — migration 146 already dropped it in this environment.';
  ELSE
    CREATE TABLE IF NOT EXISTS public.role_permissions (
      id            uuid DEFAULT gen_random_uuid() NOT NULL,
      role_id       uuid NOT NULL,
      permission_id uuid NOT NULL,
      created_at    timestamp with time zone DEFAULT now()
    );
    PERFORM pg_temp.add_constraint_if_absent('role_permissions', 'role_permissions_pkey', 'PRIMARY KEY (id)');
    PERFORM pg_temp.add_constraint_if_absent('role_permissions', 'role_permissions_role_id_permission_id_key',
      'UNIQUE (role_id, permission_id)');
    PERFORM pg_temp.add_constraint_if_absent('role_permissions', 'role_permissions_role_id_fkey',
      'FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE');
    PERFORM pg_temp.add_constraint_if_absent('role_permissions', 'role_permissions_permission_id_fkey',
      'FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE');
    CREATE INDEX IF NOT EXISTS idx_role_permissions_role ON public.role_permissions USING btree (role_id);
    CREATE INDEX IF NOT EXISTS idx_role_permissions_perm ON public.role_permissions USING btree (permission_id);
    ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;  -- only reached on first creation
  END IF;
END $$;

-- ── Verify ─────────────────────────────────────────────────────────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['modules','permissions','roles','user_roles'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE EXCEPTION 'ABORT: public.% was not created.', t;
    END IF;
  END LOOP;
  RAISE NOTICE 'Migration 20260419003 verified: RBAC core tables present.';
END $$;
