#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/deploy-functions.sh
#
# Deploy every Supabase Edge Function under supabase/functions/ to a target
# Supabase project. Idempotent — safe to re-run.
#
# Usage:
#   ./scripts/deploy-functions.sh <project-ref>
#
# Examples:
#   ./scripts/deploy-functions.sh etmnumptfadkynbsgszz     # Dev
#   ./scripts/deploy-functions.sh okpnubnswpgybpzgwgtr     # UAT / Prod-marked
#
# Notes:
#   - You must be logged in (`supabase login`) with access to the project.
#   - The functions read secrets from Supabase Vault — those need to be set
#     separately via `supabase secrets set KEY=value --project-ref <ref>`.
#   - Runs sequentially so failures are easy to spot.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <project-ref>"
  echo ""
  echo "Examples:"
  echo "  $0 etmnumptfadkynbsgszz     # Dev"
  echo "  $0 okpnubnswpgybpzgwgtr     # UAT"
  exit 1
fi

PROJECT_REF="$1"
FUNCTIONS_DIR="$(cd "$(dirname "$0")/.." && pwd)/supabase/functions"

if [[ ! -d "$FUNCTIONS_DIR" ]]; then
  echo "ERROR: functions directory not found at $FUNCTIONS_DIR"
  exit 1
fi

echo "─── Deploying Edge Functions to $PROJECT_REF ───"

FN_COUNT=0
FAILED=()

for fn_dir in "$FUNCTIONS_DIR"/*/; do
  fn_name="$(basename "$fn_dir")"
  # Skip hidden dirs and _shared (utility folders, not deployable functions)
  case "$fn_name" in
    _*|\.*)
      continue
      ;;
  esac

  FN_COUNT=$((FN_COUNT + 1))
  echo ""
  echo "── [$FN_COUNT] $fn_name ──"

  if supabase functions deploy "$fn_name" --project-ref "$PROJECT_REF"; then
    echo "   ✓ Deployed"
  else
    echo "   ✗ Failed"
    FAILED+=("$fn_name")
  fi
done

echo ""
echo "─── Summary ───"
echo "Deployed: $((FN_COUNT - ${#FAILED[@]})) / $FN_COUNT"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Failed:"
  for f in "${FAILED[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo "All functions deployed to $PROJECT_REF."
