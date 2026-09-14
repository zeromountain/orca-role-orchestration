#!/usr/bin/env bash
# Open a worktree's AI diff in Orca's diff viewer and print the review keys —
# the "Review an AI diff line-by-line" recipe. Only the first step of that
# recipe has a CLI (`orca file open-changed` / `orca file diff`); the j/k/c
# keys, inline comments and "Send to agent" are UI-only, so this script opens
# the view and then tells the human what to press.
#
#   orca-review.sh [<worktree-selector>] [--mode diff|both|edit]
#   orca-review.sh --path <file> [--staged] [<worktree-selector>]
#   orca-review.sh --race <race_id> <seat>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
RACE_LEDGER="$ORCH/race-ledger.jsonl"

usage() {
  cat <<'EOF'
Usage:
  orca-review.sh [<selector>] [--mode diff|both|edit]   open every changed file (default: active, diff)
  orca-review.sh --path <file> [--staged] [<selector>]  open one file's diff
  orca-review.sh --race <race_id> <seat>                open a race seat's worktree

Selectors: active | path:/abs/path | branch:<name> | name:<displayName>
EOF
}

SEL="active"; MODE="diff"; FILE=""; STAGED=0; RACE_ID=""; SEAT=""; DISPATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?}"; shift 2 ;;
    --path) FILE="${2:?}"; shift 2 ;;
    --staged) STAGED=1; shift ;;
    --race) RACE_ID="${2:?}"; SEAT="${3:?--race needs <race_id> <seat>}"; shift 3 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown: $1" >&2; usage; exit 1 ;;
    *) SEL="$1"; shift ;;
  esac
done
case "$MODE" in diff|both|edit) ;; *) echo "--mode must be diff|both|edit" >&2; exit 1 ;; esac

if [[ -n "$RACE_ID" ]]; then
  [[ -f "$RACE_LEDGER" ]] || { echo "review: no race ledger at $RACE_LEDGER" >&2; exit 1; }
  ROW="$(python3 - "$RACE_LEDGER" "$RACE_ID" "$SEAT" <<'PY'
import json, sys
path, race_id, seat = sys.argv[1:4]
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("kind") == "seat" and row.get("raceId") == race_id and str(row.get("seat")) == seat:
            print("%s\t%s" % (row.get("path") or "", row.get("dispatchId") or ""))
            break
PY
)"
  [[ -n "${ROW%%$'\t'*}" ]] || { echo "review: seat $SEAT of $RACE_ID has no worktree path" >&2; exit 1; }
  SEL="path:${ROW%%$'\t'*}"
  DISPATCH="${ROW#*$'\t'}"
fi

if [[ -n "$FILE" ]]; then
  STAGED_ARGS=()
  [[ "$STAGED" -eq 1 ]] && STAGED_ARGS=(--staged)
  orca file diff "$FILE" ${STAGED_ARGS[@]+"${STAGED_ARGS[@]}"} --worktree "$SEL" --json >/dev/null
  echo "Opened diff for $FILE in $SEL"
else
  orca file open-changed --mode "$MODE" --worktree "$SEL" --json >/dev/null
  echo "Opened changed files ($MODE) in $SEL"
fi

if [[ -n "$DISPATCH" ]]; then
  IFS=$'\t' read -r WS DS < <(worker_show_state "$DISPATCH" 2>/dev/null || printf '?\t?\n')
  echo "worker: $WS (dispatch $DS)"
fi

cat <<'EOF'

Review keys (Orca diff viewer — UI only, no CLI equivalent):
  j / k        next / previous file
  c            drop an inline comment on the current line (full sentences work best)
  Send to agent   batches every comment into one line-anchored prompt for the worktree's agent
                  (Settings → Shortcuts → "Send Review Notes to Agent" to bind a key)
Then: watch the status dot (yellow = needs input, green = working), reopen the
diff when idle, resolve fixed comments, repeat; commit & push from Orca when done.
EOF
