#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Snapshot this project to ~/Backups/prowess — including the files git ignores.
#
# WHY
#   Git protects committed code. It does NOT protect:
#     • .env.local and other gitignored files (secrets, local config)
#     • anything you have not committed yet
#     • the repo itself if GitHub is unreachable or the account is lost
#   This covers all three, locally.
#
# USE
#   ./scripts/backup.sh              snapshot now
#   ./scripts/backup.sh --list       show what you have
#   ./scripts/backup.sh --verify     check the newest archive is readable
#   ./scripts/backup.sh --if-changed only snapshot if something actually changed
#                                    (used by the scheduled job, so unattended
#                                    runs do not pile up identical archives)
#
#   Run it before anything risky: a big refactor, a schema change, a command
#   you are not 100% sure about.
#
# SAFETY
#   This script never deletes anything except its own .tar.gz archives inside
#   ~/Backups/prowess, by name, one at a time. There is no `rm -rf` anywhere in
#   it and no directory is ever removed.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT_DIR="${PROWESS_PROJECT_DIR:-$HOME/Developer/ET-React}"

# Where archives go. Override without editing this file:
#   export PROWESS_BACKUP_DIR="$HOME/Library/CloudStorage/OneDrive-Personal/Backups/prowess"
# Put that line in ~/.zshrc to make it permanent.
#
# OneDrive is a good target: it puts the backup OFF this machine, which a local
# Time Machine disk does not. Two things to know first:
#   • The archive contains .env.local, i.e. real secrets. On a personal or
#     company OneDrive that is usually fine, but if the folder is shared with
#     anyone, set PROWESS_EXCLUDE_ENV=1 below and keep secrets in a password
#     manager instead.
#   • Never put the WORKING REPO in OneDrive — file sync and git fight over
#     .git and will corrupt it. Only the archives belong there.
BACKUP_DIR="${PROWESS_BACKUP_DIR:-$HOME/Backups/prowess}"
KEEP="${PROWESS_KEEP:-20}"                # how many archives to retain

# ── --list ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
  if [ -d "$BACKUP_DIR" ]; then
    ls -lht "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "no backups yet"
  else
    echo "no backups yet ($BACKUP_DIR does not exist)"
  fi
  exit 0
fi

# ── --verify ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--verify" ]; then
  newest=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)
  [ -z "$newest" ] && { echo "no backups to verify"; exit 1; }
  echo "verifying $(basename "$newest") ..."
  tar -tzf "$newest" > /dev/null && echo "OK — archive is readable"
  echo "contains .env.local: $(tar -tzf "$newest" | grep -c '\.env\.local' || true)"
  echo "files: $(tar -tzf "$newest" | wc -l | tr -d ' ')"
  exit 0
fi

# ── snapshot ────────────────────────────────────────────────────────────────
[ -d "$PROJECT_DIR" ] || { echo "ERROR: $PROJECT_DIR not found"; exit 1; }
mkdir -p "$BACKUP_DIR"

IF_CHANGED=0
[ "${1:-}" = "--if-changed" ] && IF_CHANGED=1

STAMP=$(date +%Y%m%d-%H%M%S)
# Label the archive with the current commit, so you know what it corresponds to
SHA=$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
DIRTY=""
if ! git -C "$PROJECT_DIR" diff --quiet 2>/dev/null || \
   [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]; then
  DIRTY="-dirty"
fi
# --if-changed: a scheduled run has nothing useful to add when the commit is the
# same as the last archive AND the working tree is clean. Anything dirty always
# gets archived, because uncommitted work is exactly what git cannot recover.
if [ "$IF_CHANGED" = "1" ] && [ -z "$DIRTY" ]; then
  last=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)
  if [ -n "$last" ] && printf '%s' "$(basename "$last")" | grep -q -- "-$SHA\.tar\.gz$"; then
    echo "No change since $(basename "$last") — nothing to back up."
    exit 0
  fi
fi

ARCHIVE="$BACKUP_DIR/prowess-$STAMP-$SHA$DIRTY.tar.gz"

# Two runs inside the same second would otherwise produce the same filename and
# the second would silently overwrite the first. Never overwrite a backup.
n=2
while [ -e "$ARCHIVE" ]; do
  ARCHIVE="$BACKUP_DIR/prowess-$STAMP-$SHA$DIRTY-$n.tar.gz"
  n=$((n + 1))
done

echo "Backing up $PROJECT_DIR"
echo "  -> $ARCHIVE"

# Everything EXCEPT the things that rebuild themselves. .env.local IS included
# on purpose — it is the file git cannot protect.
# No bash arrays here on purpose: macOS ships bash 3.2, where expanding an
# EMPTY array under `set -u` aborts with "unbound variable". Two explicit tar
# calls are uglier but work on every shell this will ever meet.
BASE="$(basename "$PROJECT_DIR")"
PARENT="$(dirname "$PROJECT_DIR")"

if [ "${PROWESS_EXCLUDE_ENV:-0}" = "1" ]; then
  echo "  (PROWESS_EXCLUDE_ENV=1 — leaving .env.local OUT of this archive)"
  tar -czf "$ARCHIVE" -C "$PARENT" \
    --exclude="$BASE/.env.local" \
    --exclude="$BASE/node_modules" \
    --exclude="$BASE/dist" \
    --exclude="$BASE/.vite" \
    --exclude="$BASE/.DS_Store" \
    "$BASE"
else
  tar -czf "$ARCHIVE" -C "$PARENT" \
    --exclude="$BASE/node_modules" \
    --exclude="$BASE/dist" \
    --exclude="$BASE/.vite" \
    --exclude="$BASE/.DS_Store" \
    "$BASE"
fi

SIZE=$(du -h "$ARCHIVE" | cut -f1)
COUNT=$(tar -tzf "$ARCHIVE" | wc -l | tr -d ' ')
echo "  done: $SIZE, $COUNT files"

# Sanity: the whole point is capturing what git cannot.
if tar -tzf "$ARCHIVE" | grep -q '\.env\.local'; then
  echo "  .env.local captured"
else
  echo "  NOTE: no .env.local found in the project (nothing to capture)"
fi

# ── retention ───────────────────────────────────────────────────────────────
# Delete only our own archives, only in our own directory, only by full name,
# and only ever plain files. Never a directory, never recursive.
total=$(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
if [ "$total" -gt "$KEEP" ]; then
  echo "  pruning to the newest $KEEP (have $total)"
  ls -t "$BACKUP_DIR"/*.tar.gz | tail -n +$((KEEP + 1)) | while read -r old; do
    if [ -f "$old" ]; then
      rm -- "$old"
      echo "    removed $(basename "$old")"
    fi
  done
fi

echo
echo "Restore with:"
echo "  tar -xzf $ARCHIVE -C /tmp && ls /tmp/$(basename "$PROJECT_DIR")"
