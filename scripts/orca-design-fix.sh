#!/usr/bin/env bash
# "Fix a UI bug with Design Mode" recipe, minus the one step that has no CLI:
# the click. Design Mode ships the clicked element (HTML, computed CSS,
# cropped screenshot) into the ACTIVE agent terminal, so this script makes
# sure the right agent tab is the active one, navigates the worktree browser
# to the page, and tells the human what to click. `--verify` takes a
# screenshot afterwards.
#
#   orca-design-fix.sh <url> [--role ui] [--worktree <selector>]
#   orca-design-fix.sh --verify [--worktree <selector>]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
# Read by seed()/create_role() in orca-roles-lib.sh.
# shellcheck disable=SC2034
PROJECT_NAME="$(basename "$ROOT")"

usage() {
  cat <<'EOF'
Usage:
  orca-design-fix.sh <url> [--role ui] [--worktree active]
  orca-design-fix.sh --verify [--worktree active]

Ensures the role's agent tab exists and is the active terminal (Design Mode
attaches to the active agent), opens <url> in the worktree browser, then
prints the UI steps. --verify captures a screenshot of the current page.
EOF
}

URL=""; ROLE="ui"; VERIFY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="${2:?}"; shift 2 ;;
    --worktree) WORKTREE="${2:?}"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown: $1" >&2; usage; exit 1 ;;
    *) URL="$1"; shift ;;
  esac
done
WORKTREE="${WORKTREE:-active}"

if [[ "$VERIFY" -eq 1 ]]; then
  OUT="$(orca screenshot --worktree "$WORKTREE" --json)"
  printf '%s\n' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d.get("result") or {}
print("screenshot:", r.get("path") or r.get("file") or json.dumps(r)[:200])
' 2>/dev/null || printf '%s\n' "$OUT"
  echo "Click the element again in Design Mode to confirm the fix; repeat the describe → edit loop if needed, then commit."
  exit 0
fi

[[ -n "$URL" ]] || { usage; exit 1; }
validate_role "$ROLE" || exit 1
if [[ ! -f "$HANDLES_FILE" ]]; then
  echo "Missing $HANDLES_FILE — run .orca/orchestration/scripts/orca-bootstrap-roles.sh first" >&2
  exit 1
fi
if [[ -f "$ROOT/AGENTS.md" ]]; then
  CONSTRAINTS="Read and follow AGENTS.md in the project root."
elif [[ -f "$ROOT/CLAUDE.md" ]]; then
  CONSTRAINTS="Read and follow CLAUDE.md in the project root."
else
  # shellcheck disable=SC2034
  CONSTRAINTS="Follow repository conventions; never commit secrets."
fi

HANDLE="$(ensure_terminal "$ROLE")"
orca terminal switch --terminal "$HANDLE" --json >/dev/null 2>&1 \
  || echo "(warn) could not make $HANDLE the active terminal — click its tab before using Design Mode" >&2
orca goto --url "$URL" --worktree "$WORKTREE" --json >/dev/null
echo "Opened $URL in the $WORKTREE browser; $ROLE tab $HANDLE is active."
cat <<'EOF'

Now in Orca (UI only — no CLI for these):
  1. Toggle Design Mode on in the browser pane.
  2. Click the broken element — its HTML, computed CSS and a cropped screenshot
     land in the active agent tab as one attachment.
  3. Type the fix in that tab, e.g. "this padding is too tight, match the cards above".
  4. Hot reload refreshes the page; click again to confirm, repeat if needed.
  5. Commit from Orca.
Verify from here:  .orca/orchestration/or fix --verify
EOF
