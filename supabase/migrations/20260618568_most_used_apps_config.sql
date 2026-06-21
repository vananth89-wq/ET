-- ── Most Used Apps config in theme_settings ─────────────────────────────────
INSERT INTO public.theme_settings (key, value)
VALUES (
  'most_used_apps',
  '[
    {"id":"org_chart",   "label":"Org Chart",   "icon":"fa-diagram-project", "path":"/org-chart",              "visible":true,  "order":1},
    {"id":"my_requests", "label":"My Requests", "icon":"fa-list-check",      "path":"/workflow/my-requests",   "visible":true,  "order":2},
    {"id":"inbox",       "label":"Inbox",        "icon":"fa-inbox",           "path":"/workflow/inbox",          "visible":true,  "order":3},
    {"id":"delegations", "label":"Delegations", "icon":"fa-people-arrows",   "path":"/workflow/delegations",   "visible":true,  "order":4},
    {"id":"my_profile",  "label":"My Profile",  "icon":"fa-user",            "path":"/profile",                "visible":false, "order":5},
    {"id":"expense",     "label":"My Expenses", "icon":"fa-receipt",         "path":"/expense",                "visible":false, "order":6}
  ]'
)
ON CONFLICT (key) DO NOTHING;
