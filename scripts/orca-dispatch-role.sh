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
PERSIST=0
TIMEOUT_MS=900000
REAP_TIMEOUT_MS=3600000
WORKTREE="active"
PROJECT_NAME="$(basename "$ROOT")"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"
REAPER_DIR="$ORCH/reapers"

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-role.sh <architect|executor|thrifty|ui|reviewer|fallback|debater_{claude,codex,grok,gemini}> --spec "text"
  orca-dispatch-role.sh <role> --spec-file file.md [--deps '["task_id"]']
  orca-dispatch-role.sh <role> --spec "…" [--wait] [--no-reap] [--persist] [--timeout-ms N]

By default a background reaper auto-closes the worker tab when the dispatch
completes or fails (no coordinator action required).

  --wait      Also block on orca-wait-done.sh, pinned to THIS dispatch's own
              task id (--task) so it can only complete on this task's own
              message, never a leftover from an unrelated flow (optional;
              reaper still runs unless --no-reap)
  --no-reap   Disable automatic background close (tabs will linger unless closed elsewhere)
  --persist   Keep the worker tab open after worker_done (implies --no-reap).
              For multi-round flows (debate) where the caller closes tabs itself.
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
    --persist) PERSIST=1; NO_REAP=1; shift ;;
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
  architect|executor|thrifty|ui|reviewer|fallback) ;;
  debater_claude|debater_codex|debater_grok|debater_gemini) ;;
  *) echo "role must be architect|executor|thrifty|ui|reviewer|fallback|debater_{claude,codex,grok,gemini}" >&2; exit 1 ;;
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

# Dead-man watchdog registration (Task 2): completely generic and
# debate-agnostic — this script does not know or care what ORCA_ROLE_LOCK_FILE
# means (today only orca-debate.sh sets it, via its own exported env var,
# inherited by this process since orca-debate-round.sh calls this script as a
# child). If a --persist caller has an active lock context, register our
# resolved handle so that caller's watchdog knows to close it if the caller
# ever stops proving it is alive. A missing/absent lock context, or a
# non-persist dispatch, is a normal no-op — most dispatches have neither.
if [[ "$PERSIST" -eq 1 && -n "${ORCA_ROLE_LOCK_FILE:-}" && -f "$ORCA_ROLE_LOCK_FILE" ]]; then
  lock_register_handle "$ORCA_ROLE_LOCK_FILE" "$HANDLE" \
    || echo "(warn) could not register $HANDLE with lock $ORCA_ROLE_LOCK_FILE — the watchdog owning that lock will not know about this handle" >&2
fi

MODEL="$(role_meta "$ROLE" | cut -f2)"
PERSONA_FILE="$ORCH/personas/$ROLE.md"
STANCE=""
if [[ -f "$PERSONA_FILE" ]]; then
  STANCE="$(grep -m1 'STANCE:' "$PERSONA_FILE" | sed -E 's/.*STANCE:[[:space:]]*//; s/[[:space:]]*-->.*//')"
fi

# Spec always carries a tail contract: auto-close (default) or stay-open (--persist).
if [[ "$PERSIST" -eq 1 ]]; then
  TAIL_BLOCK="$(dispatch_tail_block "$HANDLE" persist)"
else
  TAIL_BLOCK="$(dispatch_tail_block "$HANDLE" close)"
fi

if [[ -n "${STANCE// }" ]]; then
  FULL_SPEC="[ROLE=$ROLE | $MODEL]
STANCE: $STANCE
$SPEC
$TAIL_BLOCK"
else
  FULL_SPEC="[ROLE=$ROLE | $MODEL]
$SPEC
$TAIL_BLOCK"
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

# Gate (Task 2): confirm the worker's actual screen, not tui-idle alone,
# before injecting — tui-idle reports success on a terminal that simply
# never finished booting (the defect this task fixes). No elapsed-time
# floor is passed here (unlike ensure_terminal's own gate before seeding
# above): this call site does not know a genuine creation timestamp for
# $HANDLE (it may have just been created moments ago by ensure_terminal,
# which already applied that floor once before seeding, or it may be a
# long-warm terminal from a prior dispatch), and re-flooring from "now" on
# every ordinary dispatch would add pure, unrequested latency to the six
# pre-existing roles' hot path for no safety benefit.
AGENT_CLI="$(role_meta "$ROLE" | cut -f3)"
if ! terminal_wait_ready "$HANDLE" "$AGENT_CLI"; then
  echo "orca-dispatch-role.sh: $HANDLE for role=$ROLE never showed a ready screen — refusing to inject. task_id=$TASK_ID was already created and is now stranded undispatched; re-run once the terminal is confirmed ready, or clear its screen by hand if it is sitting on a first-run prompt (see the screen dump above)." >&2
  exit 1
fi

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
  # --task pins this wait to the dispatch we just created (Task 4): without
  # it, a leftover worker_done from an unrelated flow (e.g. a multi-round
  # debate, which deliberately never drains its own worker_done backlog)
  # would be the first message orca-wait-done.sh sees, and --role would then
  # resolve the close target from handles.json by role name rather than from
  # that message — closing this role's real, still-running tab and
  # reporting THIS task done on the strength of someone else's completion.
  echo "Also blocking on wait-done…"
  exec "$HERE/orca-wait-done.sh" --timeout-ms "$TIMEOUT_MS" --role "$ROLE" --task "$TASK_ID"
fi

echo "Dispatched. task_id=$TASK_ID handle=$HANDLE"
echo "  status: orca orchestration dispatch-show --task $TASK_ID --json"
echo "  optional block: .orca/orchestration/scripts/orca-wait-done.sh --role $ROLE"
