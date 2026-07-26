#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/sync-auth-emails.sh
#
# Sync auth email templates between Supabase projects using the Management API.
# Templates live only in each project's dashboard — the CLI/migrations don't
# cover them. This script closes that gap.
#
# Two modes:
#   pull <source-ref>              — fetch templates from source project,
#                                    save to supabase/auth/emails/*.html
#   push <target-ref>              — read local files, push to target project
#   copy <source-ref> <target-ref> — pull then push in one shot
#
# Requires:
#   - SUPABASE_ACCESS_TOKEN env var set (get from
#     https://supabase.com/dashboard/account/tokens)
#   - jq installed  (brew install jq)
#
# Examples:
#   export SUPABASE_ACCESS_TOKEN=sbp_xxxx
#   ./scripts/sync-auth-emails.sh copy okpnubnswpgybpzgwgtr etmnumptfadkynbsgszz
#   ./scripts/sync-auth-emails.sh pull okpnubnswpgybpzgwgtr
#   ./scripts/sync-auth-emails.sh push etmnumptfadkynbsgszz
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

if [[ -z "${SUPABASE_ACCESS_TOKEN:-}" ]]; then
  echo "ERROR: SUPABASE_ACCESS_TOKEN not set."
  echo "Get one from https://supabase.com/dashboard/account/tokens and export it."
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "ERROR: jq is required. Install: brew install jq"
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMAILS_DIR="$REPO_ROOT/supabase/auth/emails"
mkdir -p "$EMAILS_DIR"

# Template mapping: dashboard label → API field name → local filename
declare -A TEMPLATES=(
  ["confirm-signup"]="mailer_templates_confirmation_content"
  ["invite"]="mailer_templates_invite_content"
  ["magic-link"]="mailer_templates_magic_link_content"
  ["change-email"]="mailer_templates_email_change_content"
  ["reset-password"]="mailer_templates_recovery_content"
)

declare -A SUBJECTS=(
  ["confirm-signup"]="mailer_subjects_confirmation"
  ["invite"]="mailer_subjects_invite"
  ["magic-link"]="mailer_subjects_magic_link"
  ["change-email"]="mailer_subjects_email_change"
  ["reset-password"]="mailer_subjects_recovery"
)

pull() {
  local ref="$1"
  echo "── Pulling auth config from project $ref ──"
  local config
  config=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    "https://api.supabase.com/v1/projects/$ref/config/auth")

  if echo "$config" | jq -e '.message' >/dev/null 2>&1; then
    echo "API error: $(echo "$config" | jq -r '.message')"
    exit 1
  fi

  local subjects_json="{}"
  for key in "${!TEMPLATES[@]}"; do
    local api_field="${TEMPLATES[$key]}"
    local subject_field="${SUBJECTS[$key]}"
    local html; html=$(echo "$config" | jq -r ".$api_field // \"\"")
    local subject; subject=$(echo "$config" | jq -r ".$subject_field // \"\"")

    if [[ -n "$html" && "$html" != "null" ]]; then
      echo "$html" > "$EMAILS_DIR/$key.html"
      echo "  ✓ $key.html ($(wc -c < "$EMAILS_DIR/$key.html") bytes)"
    else
      echo "  ⚠ $key — empty (uses Supabase default)"
    fi

    subjects_json=$(echo "$subjects_json" | jq --arg k "$key" --arg v "$subject" '. + {($k): $v}')
  done

  echo "$subjects_json" | jq . > "$EMAILS_DIR/subjects.json"
  echo "  ✓ subjects.json"
  echo "Pull complete. Files in $EMAILS_DIR"
}

push() {
  local ref="$1"
  echo "── Pushing auth config to project $ref ──"

  local subjects_file="$EMAILS_DIR/subjects.json"
  if [[ ! -f "$subjects_file" ]]; then
    echo "ERROR: $subjects_file not found. Run 'pull' first."
    exit 1
  fi

  local patch="{}"
  for key in "${!TEMPLATES[@]}"; do
    local api_field="${TEMPLATES[$key]}"
    local subject_field="${SUBJECTS[$key]}"
    local html_file="$EMAILS_DIR/$key.html"

    if [[ -s "$html_file" ]]; then
      local html; html=$(cat "$html_file")
      patch=$(echo "$patch" | jq --arg k "$api_field" --arg v "$html" '. + {($k): $v}')
    fi

    local subject; subject=$(jq -r ".\"$key\" // \"\"" "$subjects_file")
    if [[ -n "$subject" && "$subject" != "null" ]]; then
      patch=$(echo "$patch" | jq --arg k "$subject_field" --arg v "$subject" '. + {($k): $v}')
    fi
  done

  echo "Patch payload keys: $(echo "$patch" | jq -r 'keys | join(", ")')"

  local response
  response=$(curl -s -X PATCH \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$patch" \
    "https://api.supabase.com/v1/projects/$ref/config/auth")

  if echo "$response" | jq -e '.message' >/dev/null 2>&1; then
    echo "API error: $(echo "$response" | jq -r '.message')"
    exit 1
  fi

  echo "Push complete."
}

case "${1:-}" in
  pull)
    [[ $# -eq 2 ]] || { echo "Usage: $0 pull <source-ref>"; exit 1; }
    pull "$2"
    ;;
  push)
    [[ $# -eq 2 ]] || { echo "Usage: $0 push <target-ref>"; exit 1; }
    push "$2"
    ;;
  copy)
    [[ $# -eq 3 ]] || { echo "Usage: $0 copy <source-ref> <target-ref>"; exit 1; }
    pull "$2"
    push "$3"
    ;;
  *)
    echo "Usage: $0 {pull|push|copy} <ref> [<target-ref>]"
    echo ""
    echo "  pull  <source-ref>              — save templates to supabase/auth/emails/"
    echo "  push  <target-ref>              — push local templates to target project"
    echo "  copy  <source-ref> <target-ref> — pull then push"
    echo ""
    echo "Refs:"
    echo "  Dev   = etmnumptfadkynbsgszz"
    echo "  UAT   = okpnubnswpgybpzgwgtr"
    exit 1
    ;;
esac
