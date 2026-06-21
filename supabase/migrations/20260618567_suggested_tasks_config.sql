-- ── Suggested Tasks config in theme_settings ────────────────────────────────
-- Stores an ordered JSON array of { id, label, path, visible, order }
-- Admin can toggle visibility and reorder via Theme Manager.

INSERT INTO public.theme_settings (key, value)
VALUES (
  'suggested_tasks',
  '[
    {"id":"my_profile",         "label":"My Profile",            "path":"/profile",                "visible":true,  "order":1},
    {"id":"my_expense_reports", "label":"My Expense Reports",    "path":"/expense",                "visible":true,  "order":2},
    {"id":"create_expense",     "label":"Create Expense Report", "path":"/expense/new",            "visible":false, "order":3},
    {"id":"org_chart",          "label":"Org Chart",             "path":"/org-chart",              "visible":false, "order":4},
    {"id":"my_requests",        "label":"My Requests",           "path":"/workflow/my-requests",   "visible":false, "order":5},
    {"id":"inbox",              "label":"Inbox",                 "path":"/workflow/inbox",          "visible":false, "order":6},
    {"id":"delegations",        "label":"Delegations",           "path":"/workflow/delegations",   "visible":false, "order":7}
  ]'
)
ON CONFLICT (key) DO NOTHING;
