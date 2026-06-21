-- ── Redesign landing_announcements as "Create Card" wizard schema ────────────
-- Drop old columns, add new ones matching the 4-step wizard:
-- 1. General: name, description, is_active (enabled)
-- 2. Card: card_type, title, subtitle, image_url, alt_text
-- 3. Navigation: nav_target, rule_based, open_new_tab, url, show_in_app
-- 4. Assignments: target_group_type, target_groups, folder, active_period,
--                 active_from, active_to, days_before_start, days_after_start,
--                 days_before_term, days_after_term

-- Remove old columns
ALTER TABLE public.landing_announcements
  DROP COLUMN IF EXISTS tagline,
  DROP COLUMN IF EXISTS content,
  DROP COLUMN IF EXISTS bg_color,
  DROP COLUMN IF EXISTS title_color,
  DROP COLUMN IF EXISTS tagline_color,
  DROP COLUMN IF EXISTS content_color,
  DROP COLUMN IF EXISTS text_align,
  DROP COLUMN IF EXISTS button_text,
  DROP COLUMN IF EXISTS button_url,
  DROP COLUMN IF EXISTS button_new_tab,
  DROP COLUMN IF EXISTS target_group;

-- Rename bg_image_url → image_url
ALTER TABLE public.landing_announcements
  RENAME COLUMN bg_image_url TO image_url;

-- Add new columns
ALTER TABLE public.landing_announcements
  ADD COLUMN IF NOT EXISTS description      TEXT,
  ADD COLUMN IF NOT EXISTS card_type        TEXT    NOT NULL DEFAULT 'Image',
  ADD COLUMN IF NOT EXISTS subtitle         TEXT,
  ADD COLUMN IF NOT EXISTS alt_text         TEXT,
  ADD COLUMN IF NOT EXISTS nav_target       TEXT    NOT NULL DEFAULT 'URL',
  ADD COLUMN IF NOT EXISTS rule_based       BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS open_new_tab     BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS url              TEXT,
  ADD COLUMN IF NOT EXISTS show_in_app      TEXT    NOT NULL DEFAULT 'web_only',
  ADD COLUMN IF NOT EXISTS target_group_type TEXT   NOT NULL DEFAULT 'dynamic',
  ADD COLUMN IF NOT EXISTS target_groups    TEXT    NOT NULL DEFAULT 'Everyone (All Employees)',
  ADD COLUMN IF NOT EXISTS folder           TEXT    NOT NULL DEFAULT 'Default',
  ADD COLUMN IF NOT EXISTS active_period    TEXT    NOT NULL DEFAULT 'always',
  ADD COLUMN IF NOT EXISTS days_before_start INT,
  ADD COLUMN IF NOT EXISTS days_after_start  INT,
  ADD COLUMN IF NOT EXISTS days_before_term  INT,
  ADD COLUMN IF NOT EXISTS days_after_term   INT;
