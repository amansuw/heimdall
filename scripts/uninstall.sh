#!/usr/bin/env bash
#
# Heimdall uninstaller.
#
# Removing Heimdall.app on its own is not enough: fan control needs a root
# LaunchDaemon, and that daemon keeps running after the app is dragged to the
# Trash. This script removes the app, the daemon, and everything the daemon
# leaves on disk.
#
# Every step is safe to run when the thing it removes is already gone, so it is
# fine to run this twice, or after a partial manual cleanup.
#
# Usage:
#   ./scripts/uninstall.sh              # explain, ask, then remove
#   ./scripts/uninstall.sh --dry-run    # show what would be removed, change nothing
#   ./scripts/uninstall.sh --yes        # skip the confirmation prompt
#   ./scripts/uninstall.sh --keep-settings
#                                       # leave your Heimdall preferences in place

set -euo pipefail

DAEMON_LABEL="com.heimdall.smchelper"
APP_BUNDLE_ID="com.heimdall.app"
APP_PATH="/Applications/Heimdall.app"
PLIST_PATH="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
# The root helper runs from its own root-owned copy of the app.
HELPER_PATH="/Library/PrivilegedHelperTools/${DAEMON_LABEL}.app"

# Current runtime paths.
SYSTEM_PATHS=(
  "$PLIST_PATH"
  "$HELPER_PATH"
  "/var/run/heimdall"
  "/var/log/heimdall-daemon.log"
)

# Paths used by earlier builds. Harmless if absent; removed so an upgrade from
# an old version does not leave stale FIFOs and logs behind.
LEGACY_PATHS=(
  "/tmp/heimdall-smc-cmd"
  "/tmp/heimdall-smc-rsp"
  "/tmp/heimdall-smc-ready"
  "/tmp/heimdall-daemon.log"
)

# Per-user files. Removed unless --keep-settings is passed.
USER_PATHS=(
  "$HOME/Library/Preferences/${APP_BUNDLE_ID}.plist"
  "$HOME/Library/Saved Application State/${APP_BUNDLE_ID}.savedState"
  "$HOME/Library/Caches/${APP_BUNDLE_ID}"
  "$HOME/Library/HTTPStorages/${APP_BUNDLE_ID}"
  "$HOME/Library/HTTPStorages/${APP_BUNDLE_ID}.binarycookies"
)

DRY_RUN=0
ASSUME_YES=0
KEEP_SETTINGS=0

REMOVED=0
SKIPPED=0
FAILED=0

usage() {
  # Print the header comment block (from line 3 to the first non-comment line).
  awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)      DRY_RUN=1 ;;
    -y|--yes)          ASSUME_YES=1 ;;
    --keep-settings)   KEEP_SETTINGS=1 ;;
    -h|--help)         usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Try: $0 --help" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This uninstaller only runs on macOS." >&2
  exit 1
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

# run <description> <command...>
# Honours --dry-run and never aborts the script on failure.
run() {
  local desc="$1"
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would run: $*"
    return 0
  fi
  if "$@" >/dev/null 2>&1; then
    say "  ok: $desc"
    return 0
  fi
  return 1
}

# remove_path <path> [sudo]
remove_path() {
  local path="$1"
  local privileged="${2:-}"

  if [ -z "$path" ] || [ "$path" = "/" ]; then
    say "  refusing to remove suspicious path: '${path}'"
    FAILED=$((FAILED + 1))
    return 0
  fi

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    say "  not present: $path"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would remove: $path"
    REMOVED=$((REMOVED + 1))
    return 0
  fi

  if [ "$privileged" = "sudo" ]; then
    if sudo rm -rf -- "$path"; then
      say "  removed: $path"
      REMOVED=$((REMOVED + 1))
    else
      say "  FAILED to remove: $path"
      FAILED=$((FAILED + 1))
    fi
  else
    if rm -rf -- "$path"; then
      say "  removed: $path"
      REMOVED=$((REMOVED + 1))
    else
      say "  FAILED to remove: $path"
      FAILED=$((FAILED + 1))
    fi
  fi
}

# ---------------------------------------------------------------------------
# Explain first.
# ---------------------------------------------------------------------------

cat <<PLAN
Heimdall uninstaller
====================

This will:

  1. Quit Heimdall if it is running.
  2. Reset your fans to macOS automatic control (so they are never left pinned
     at a speed Heimdall chose).
  3. Stop and unload the root background helper:
       launchctl bootout system/${DAEMON_LABEL}
  4. Delete these system files (requires your admin password):
PLAN

for p in "${SYSTEM_PATHS[@]}"; do
  printf '       %s\n' "$p"
done

cat <<PLAN
  5. Delete the app:
       ${APP_PATH}
  6. Delete leftovers from older versions:
PLAN

for p in "${LEGACY_PATHS[@]}"; do
  printf '       %s\n' "$p"
done

if [ "$KEEP_SETTINGS" -eq 1 ]; then
  say "  7. Keep your Heimdall settings (--keep-settings was passed)."
else
  cat <<'PLAN'
  7. Delete your Heimdall settings (fan profiles, custom curves, window state):
PLAN
  for p in "${USER_PATHS[@]}"; do
    printf '       %s\n' "$p"
  done
  say ""
  say "     Pass --keep-settings to leave those in place."
fi

cat <<'PLAN'

Nothing else on your Mac is touched. Anything already gone is skipped.
PLAN

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "DRY RUN: nothing will actually be changed."
fi

# ---------------------------------------------------------------------------
# Confirm.
# ---------------------------------------------------------------------------

if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  say ""
  reply=""
  if [ -r /dev/tty ]; then
    printf 'Continue? [y/N] '
    read -r reply < /dev/tty || reply=""
  elif [ -t 0 ]; then
    printf 'Continue? [y/N] '
    read -r reply || reply=""
  else
    echo "No terminal available to confirm. Re-run with --yes to proceed." >&2
    exit 1
  fi
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) say "Cancelled. Nothing was changed."; exit 0 ;;
  esac
fi

# Ask for the admin password once, up front, so later steps do not each prompt.
if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  step "Requesting administrator access"
  if ! sudo -v; then
    echo "Could not obtain administrator access. Aborting." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Quit the app.
# ---------------------------------------------------------------------------

step "Quitting Heimdall"
if pgrep -x Heimdall >/dev/null 2>&1; then
  run "asked Heimdall to quit" osascript -e "tell application id \"${APP_BUNDLE_ID}\" to quit" || true
  if [ "$DRY_RUN" -eq 0 ]; then
    for _ in 1 2 3 4 5; do
      pgrep -x Heimdall >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -x Heimdall >/dev/null 2>&1; then
      run "force-quit Heimdall" pkill -x Heimdall || say "  could not stop Heimdall; continuing"
    else
      say "  ok: Heimdall quit"
    fi
  fi
else
  say "  not running"
fi

# ---------------------------------------------------------------------------
# 2. Hand the fans back to macOS.
# ---------------------------------------------------------------------------

step "Returning fans to automatic control"
# Either binary can do this; the helper copy is still there if the app was
# already dragged to the Trash.
RESET_BIN=""
for candidate in "${APP_PATH}/Contents/MacOS/Heimdall" "${HELPER_PATH}/Contents/MacOS/Heimdall"; do
  if [ -x "$candidate" ]; then
    RESET_BIN="$candidate"
    break
  fi
done
if [ -n "$RESET_BIN" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  would run: sudo ${RESET_BIN} --reset-fans"
  elif sudo "$RESET_BIN" --reset-fans >/dev/null 2>&1; then
    say "  ok: fans reset to automatic"
  else
    say "  could not reset fans (harmless: macOS reclaims fan control on reboot)"
  fi
else
  say "  no Heimdall binary present; skipping"
fi

# ---------------------------------------------------------------------------
# 3. Stop the root helper.
# ---------------------------------------------------------------------------

step "Stopping the background helper (${DAEMON_LABEL})"
if [ "$DRY_RUN" -eq 1 ]; then
  say "  would run: sudo launchctl bootout system/${DAEMON_LABEL}"
elif sudo launchctl bootout "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
  say "  ok: helper stopped and unloaded"
else
  # bootout exits non-zero when the service was never loaded. That is a
  # success for our purposes, so only report a problem if it is still there.
  if sudo launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
    say "  FAILED: helper is still loaded; try again after a reboot"
    FAILED=$((FAILED + 1))
  else
    say "  not loaded"
  fi
fi

# ---------------------------------------------------------------------------
# 4-6. Delete files.
# ---------------------------------------------------------------------------

step "Removing system files"
for p in "${SYSTEM_PATHS[@]}"; do
  remove_path "$p" sudo
done

step "Removing the app"
remove_path "$APP_PATH" sudo

step "Removing leftovers from older versions"
for p in "${LEGACY_PATHS[@]}"; do
  remove_path "$p" sudo
done

if [ "$KEEP_SETTINGS" -eq 1 ]; then
  step "Keeping your settings (--keep-settings)"
else
  step "Removing your settings"
  for p in "${USER_PATHS[@]}"; do
    remove_path "$p"
  done
  if [ "$DRY_RUN" -eq 0 ]; then
    # Preferences are cached by cfprefsd, so the plist can reappear unless the
    # domain is cleared too.
    defaults delete "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  fi
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------

step "Done"
say "  removed: ${REMOVED}   already gone: ${SKIPPED}   failed: ${FAILED}"

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "That was a dry run. Re-run without --dry-run to actually remove Heimdall."
  exit 0
fi

if [ "$FAILED" -gt 0 ]; then
  say ""
  say "Some items could not be removed. Re-run this script, or reboot and re-run it."
  exit 1
fi

say ""
say "Heimdall has been removed."
