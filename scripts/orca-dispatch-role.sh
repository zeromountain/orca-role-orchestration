#!/usr/bin/env bash
# Dispatch supervised Orca task to a role worker.
# Usage:
#   .orca/orchestration/scripts/orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "..."
#   .orca/orchestration/scripts/orca-dispatch-role.sh architect --spec-file path.md [--deps '["task_xxx"]']
#
# Role tabs are ephemeral. After inject, a background reaper watches dispatch
# status and auto-closes the worker tab on completed|failed (no manual step).
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
NO_REAP=0
TIMEOUT_MS=900000
REAP_TIMEOUT_MS=3600000
WORKTREE="active"
PROJECT_NAME="$(basename "$ROOT")"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"
REAPER_DIR="$ORCH/reapers"

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "text"
  orca-dispatch-role.sh <role> --spec-file file.md [--deps '["task_id"]']
  orca-dispatch-role.sh <role> --spec "…" [--wait] [--no-reap] [--timeout-ms N]

By default a background reaper auto-closes the worker tab when the dispatch
completes or fails (no coordinator action required).

  --wait      Also block on orca-wait-done.sh (optional; reaper still runs unless --no-reap)
  --no-reap   Disable automatic background close (tabs will linger unless closed elsewhere)
  --timeout-ms  Timeout for --wait only (default 900000). Reaper default lifetime 1h.
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
    --no-reap) NO_REAP=1; shift ;;
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

# Spec always carries auto-close contract so the worker also self-closes after worker_done.
AUTO_CLOSE_BLOCK="
AUTO-CLOSE (required, automatic):
After you send worker_done exactly once, immediately run this shell command (do not skip):
  orca terminal close --terminal ${HANDLE} --tab --json
Your Orca terminal handle for this session is: ${HANDLE}
Then stop. Do not poll orchestration. A background reaper also closes this tab if needed.
"

if [[ -n "${STANCE// }" ]]; then
  FULL_SPEC="[ROLE=$ROLE | $MODEL]
STANCE: $STANCE
$SPEC
$AUTO_CLOSE_BLOCK"
else
  FULL_SPEC="[ROLE=$ROLE | $MODEL]
$SPEC
$AUTO_CLOSE_BLOCK"
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

# Ledger for reaper / wait-done
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

# Background reaper: auto-close on completed|failed (default ON)
if [[ "$NO_REAP" -eq 0 ]]; then
  mkdir -p "$REAPER_DIR"
  LOG="$REAPER_DIR/${TASK_ID}.log"
  PID_FILE="$REAPER_DIR/${TASK_ID}.pid"
  nohup "$HERE/orca-reap-task.sh" \
    --task "$TASK_ID" \
    --handle "$HANDLE" \
    --role "$ROLE" \
    --timeout-ms "$REAP_TIMEOUT_MS" \
    >>"$LOG" 2>&1 &
  echo $! >"$PID_FILE"
  echo "Auto-reaper started pid=$(cat "$PID_FILE") log=$LOG"
  echo "Worker tab will close automatically when dispatch completes."
else
  echo "Reaper disabled (--no-reap). Tab will linger unless closed elsewhere."
fi

if [[ "$WAIT_DONE" -eq 1 ]]; then
  echo "Also blocking on wait-done…"
  exec "$HERE/orca-wait-done.sh" --timeout-ms "$TIMEOUT_MS" --role "$ROLE"
fi

echo "Dispatched. task_id=$TASK_ID handle=$HANDLE"
echo "  status: orca orchestration dispatch-show --task $TASK_ID --json"
echo "  optional block: .orca/orchestration/scripts/orca-wait-done.sh --role $ROLE"
