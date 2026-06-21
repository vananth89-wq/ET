-- Migration: landing_announcements
-- Purpose: Stores admin-managed announcement banners shown on the employee landing page.
-- Next mig: 20260617566+

-- ── Table ─────────────────────────────────────────────────────────────────────

create table if not exists landing_announcements (
  id              uuid        primary key default gen_random_uuid(),
  name            text        not null,                        -- internal admin reference
  title           text,
  tagline         text,
  content         text,
  bg_image_url    text,
  bg_color        text        default '#1565c0',
  title_color     text        default '#ffffff',
  tagline_color   text        default '#ffffff',
  content_color   text        default '#ffffffcc',
  text_align      text        default 'left'
                    check (text_align in ('left','center','right')),
  button_text     text,
  button_url      text,
  button_new_tab  boolean     not null default true,
  is_active       boolean     not null default true,
  active_from     date,
  active_to       date,
  target_group    text        default 'Everyone (All Employees)',
  sort_order      integer     not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ── Indexes ───────────────────────────────────────────────────────────────────

create index if not exists idx_landing_announcements_active
  on landing_announcements (is_active, active_from, active_to);

create index if not exists idx_landing_announcements_sort
  on landing_announcements (sort_order, created_at desc);

-- ── updated_at trigger ────────────────────────────────────────────────────────

create or replace function trg_set_updated_at_landing_ann()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_landing_announcements_updated_at on landing_announcements;
create trigger trg_landing_announcements_updated_at
  before update on landing_announcements
  for each row execute function trg_set_updated_at_landing_ann();

-- ── RLS ───────────────────────────────────────────────────────────────────────

alter table landing_announcements enable row level security;

-- Authenticated users can read active announcements
create policy "landing_announcements_select" on landing_announcements
  for select to authenticated
  using (true);

-- Only super admins / theme_manager permission holders can write
create policy "landing_announcements_insert" on landing_announcements
  for insert to authenticated
  with check (is_super_admin() or user_can('theme_manager', 'view', NULL));

create policy "landing_announcements_update" on landing_announcements
  for update to authenticated
  using  (is_super_admin() or user_can('theme_manager', 'view', NULL))
  with check (is_super_admin() or user_can('theme_manager', 'view', NULL));

create policy "landing_announcements_delete" on landing_announcements
  for delete to authenticated
  using (is_super_admin() or user_can('theme_manager', 'view', NULL));

-- ── Extend get_theme_settings to include landing keys ────────────────────────
-- The existing get_theme_settings RPC returns a JSONB of all theme_settings rows.
-- landing_hero_image and landing_graphic_image will automatically be included
-- once upserted via the existing upsert_theme_setting RPC — no schema change needed.
