#!/usr/bin/env bash
# Dispatch supervised Orca task to a role worker.
# Usage:
#   .orca/orchestration/scripts/orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "..."
#   .orca/orchestration/scripts/orca-dispatch-role.sh architect --spec-file path.md [--deps '["task_xxx"]']
#
# Role tabs are ephemeral: wait with orca-wait-done.sh (or --wait) so worker
# tabs auto-close on worker_done. This script recreates a dead/missing terminal.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
ROLE=""
SPEC=""
SPEC_FILE=""
DEPS="[]"
WAIT_DONE=0
TIMEOUT_MS=900000
WORKTREE="active"
PROJECT_NAME="$(basename "$ROOT")"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "text"
  orca-dispatch-role.sh <role> --spec-file file.md [--deps '["task_id"]']
  orca-dispatch-role.sh <role> --spec "…" --wait [--timeout-ms N]

fallback = Antigravity Gemini 3.5 Flash (Medium) for rate/session limits.
Recreates the role terminal if the stored handle is dead/missing.
--wait runs orca-wait-done.sh after inject (auto-closes the worker tab on worker_done).
Without --wait, prefer:
  .orca/orchestration/scripts/orca-wait-done.sh --role <role>
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi
ROLE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC="${2:?}"; shift 2 ;;
    --spec-file) SPEC_FILE="${2:?}"; shift 2 ;;
    --deps) DEPS="${2:?}"; shift 2 ;;
    --wait) WAIT_DONE=1; shift ;;
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$HANDLES_FILE" ]]; then
  echo "Missing $HANDLES_FILE — run .orca/orchestration/scripts/orca-bootstrap-roles.sh first" >&2
  exit 1
fi

case "$ROLE" in
  architect|executor|thrifty|fallback) ;;
  *) echo "role must be architect|executor|thrifty|fallback" >&2; exit 1 ;;
esac
if [[ -n "$SPEC_FILE" ]]; then SPEC="$(cat "$SPEC_FILE")"; fi
if [[ -z "${SPEC// }" ]]; then echo "--spec or --spec-file required" >&2; exit 1; fi

# Project context for seed() if recreate path runs
WORKTREE="$(python3 - "$HANDLES_FILE" <<'PY' 2>/dev/null || echo active
import json, sys
with open(sys.argv[1]) as stream:
    print(json.load(stream).get("worktree") or "active")
PY
)"
if [[ -f "$ROOT/package.json" ]]; then
  PROJECT_NAME="$(python3 - "$ROOT/package.json" "$PROJECT_NAME" <<'PY' 2>/dev/null || echo "$PROJECT_NAME"
import json, sys
with open(sys.argv[1]) as stream:
    print(json.load(stream).get("name") or sys.argv[2])
PY
)"
fi
if [[ -f "$ROOT/AGENTS.md" ]]; then
  CONSTRAINTS="Read and follow AGENTS.md in the project root."
elif [[ -f "$ROOT/CLAUDE.md" ]]; then
  CONSTRAINTS="Read and follow CLAUDE.md in the project root."
else
  CONSTRAINTS="Follow repository conventions; never commit secrets."
fi

HANDLE="$(ensure_terminal "$ROLE")"
MODEL="$(role_meta "$ROLE" | cut -f2)"
PERSONA_FILE="$ORCH/personas/$ROLE.md"
STANCE=""
if [[ -f "$PERSONA_FILE" ]]; then
  STANCE="$(grep -m1 'STANCE:' "$PERSONA_FILE" | sed -E 's/.*STANCE:[[:space:]]*//; s/[[:space:]]*-->.*//')"
fi
if [[ -n "${STANCE// }" ]]; then
  FULL_SPEC="[ROLE=$ROLE | $MODEL]
STANCE: $STANCE
$SPEC"
else
  FULL_SPEC="[ROLE=$ROLE | $MODEL]
$SPEC"
fi

echo "Creating task for ROLE=$ROLE → $HANDLE"
CREATE_JSON="$(orca orchestration task-create --deps "$DEPS" --spec "$FULL_SPEC" --json)"
TASK_ID="$(printf '%s' "$CREATE_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
r=d.get("result") or d
t=r.get("task") or r
print(t.get("id") or t.get("task_id") or r.get("id") or "")
')"
if [[ -z "$TASK_ID" ]]; then
  echo "Failed to parse task id:" >&2
  echo "$CREATE_JSON" >&2
  exit 1
fi
echo "task_id=$TASK_ID"

echo "Waiting for worker tui-idle…"
orca terminal wait --terminal "$HANDLE" --for tui-idle --timeout-ms 90000 --json >/dev/null || true

echo "Dispatching (inject)…"
DISPATCH_JSON="$(orca orchestration dispatch --task "$TASK_ID" --to "$HANDLE" --inject --json)"
printf '%s\n' "$DISPATCH_JSON"
DISPATCH_ID="$(printf '%s' "$DISPATCH_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin)
r=d.get("result") or d
disp=r.get("dispatch") or r
print(disp.get("id") or disp.get("dispatch_id") or "")
' 2>/dev/null || true)"

# Ledger for wait-done auto-close (taskId → handle/role)
python3 - "$LEDGER_FILE" "$TASK_ID" "$DISPATCH_ID" "$ROLE" "$HANDLE" <<'PY'
import json, sys, datetime, os
path, task_id, dispatch_id, role, handle = sys.argv[1:6]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
row = {
    "taskId": task_id,
    "dispatchId": dispatch_id or None,
    "role": role,
    "handle": handle,
    "status": "dispatched",
    "dispatchedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
print(f"ledger += {role} {task_id} → {handle}", file=sys.stderr)
PY

if [[ "$WAIT_DONE" -eq 1 ]]; then
  echo "Waiting for worker_done (auto-close on completion)…"
  exec "$HERE/orca-wait-done.sh" --timeout-ms "$TIMEOUT_MS" --role "$ROLE"
fi

echo "Dispatched. Prefer wait+auto-close:"
echo "  .orca/orchestration/scripts/orca-wait-done.sh --role $ROLE --timeout-ms $TIMEOUT_MS"
echo "  orca orchestration dispatch-show --task $TASK_ID --json"
echo "Manual close (if not using wait-done):"
echo "  .orca/orchestration/scripts/orca-close-role.sh $ROLE"
