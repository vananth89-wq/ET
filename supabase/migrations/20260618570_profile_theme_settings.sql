-- ── Employee Profile theme settings ──────────────────────────────────────────
-- profile_hero_image: URL of the banner shown at the top of the profile page
-- profile_sections:   JSON array controlling section order + visibility

INSERT INTO public.theme_settings (key, value)
VALUES ('profile_hero_image', null)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.theme_settings (key, value)
VALUES (
  'profile_sections',
  '[
    {"id":"personal",          "label":"Personal Information", "icon":"fa-circle-user",       "visible":true,  "order":1},
    {"id":"contact",           "label":"Contact",              "icon":"fa-address-book",       "visible":true,  "order":2},
    {"id":"employment",        "label":"Employment",           "icon":"fa-briefcase",          "visible":true,  "order":3},
    {"id":"address",           "label":"Address",              "icon":"fa-location-dot",       "visible":true,  "order":4},
    {"id":"passport",          "label":"Passport",             "icon":"fa-passport",           "visible":true,  "order":5},
    {"id":"identification",    "label":"Identification",       "icon":"fa-id-card",            "visible":true,  "order":6},
    {"id":"emergency",         "label":"Emergency Contact",    "icon":"fa-phone-volume",       "visible":true,  "order":7},
    {"id":"bank",              "label":"Bank Accounts",        "icon":"fa-building-columns",   "visible":true,  "order":8},
    {"id":"dependents",        "label":"Dependents",           "icon":"fa-people-group",       "visible":true,  "order":9},
    {"id":"job_relationships", "label":"Job Relationships",    "icon":"fa-sitemap",            "visible":true,  "order":10},
    {"id":"education",         "label":"Education",            "icon":"fa-graduation-cap",     "visible":true,  "order":11}
  ]'
)
ON CONFLICT (key) DO NOTHING;
