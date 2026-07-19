#!/usr/bin/env bash
# Close a role worker terminal after worker_done (ephemeral tabs).
# Usage:
#   .orca/orchestration/scripts/orca-close-role.sh <architect|executor|thrifty|fallback|term_*>
# Idempotent: missing/dead handle → exit 0.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"

usage() {
  cat <<'EOF'
Usage:
  orca-close-role.sh <architect|executor|thrifty|fallback|term_*>

Closes the role's Orca terminal (kills PTY). Safe to call twice.
Does not edit handles.json — next dispatch recreates via ensure_terminal.
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi
TARGET="$1"
if [[ "$TARGET" == "-h" || "$TARGET" == "--help" ]]; then usage; exit 0; fi

HANDLE=""
if [[ "$TARGET" == term_* ]]; then
  HANDLE="$TARGET"
else
  case "$TARGET" in
    architect|executor|thrifty|fallback) ;;
    *) echo "role must be architect|executor|thrifty|fallback|term_*" >&2; exit 1 ;;
  esac
  if [[ ! -f "$HANDLES_FILE" ]]; then
    echo "No $HANDLES_FILE — nothing to close (ok)"
    exit 0
  fi
  HANDLE="$(handles_get "$HANDLES_FILE" "$TARGET")"
fi

if [[ -z "${HANDLE// }" ]]; then
  echo "No handle for $TARGET — already closed (ok)"
  exit 0
fi

if ! terminal_is_live "$HANDLE"; then
  echo "Handle $HANDLE already gone (ok)"
  exit 0
fi

echo "Closing $TARGET → $HANDLE (tab)"
# Prefer --tab so the whole sub-session leaves the sidebar (not just the pane).
if orca terminal close --terminal "$HANDLE" --tab --json >/dev/null 2>&1 \
  || orca terminal close --terminal "$HANDLE" --json >/dev/null 2>&1; then
  echo "Closed $HANDLE"
else
  echo "Close returned non-zero for $HANDLE (treating as ok — may already be gone)"
fi
exit 0
