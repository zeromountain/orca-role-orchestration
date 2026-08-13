#!/usr/bin/env bash
# Attach a worker to an ALREADY-CREATED Orca task — no task-create. Two
# callers:
#   - the coordinator, dispatching a later orca-dispatch-dag.sh wave once
#     `orca orchestration task-list --ready --json` shows it ready
#   - orca-fallback-on-limit.sh, retrying the SAME task on a different
#     vendor via --retry-of (keeps task-list lineage instead of forking a
#     new, unrelated task — see references/orca-contract-2026-08-13.md 2-b)
#
# Usage:
#   orca-dispatch-existing.sh <task_id> <role> [--retry-of dispatch_id] [--no-reap]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"
NO_REAP=0
RETRY_OF=""
REAP_TIMEOUT_MS=3600000

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-existing.sh <task_id> <role> [--retry-of dispatch_id] [--no-reap]

<role>: architect|executor|thrifty|ui|reviewer|fallback|debater_{claude,codex,grok,gemini}
EOF
}

if [[ $# -lt 2 ]]; then usage; exit 1; fi
TASK_ID="$1"; ROLE="$2"; shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --retry-of) RETRY_OF="${2:?}"; shift 2 ;;
    --no-reap) NO_REAP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$HANDLES_FILE" ]]; then
  echo "Missing $HANDLES_FILE — run .orca/orchestration/scripts/orca-bootstrap-roles.sh first" >&2
  exit 1
fi
validate_role "$ROLE" || exit 1
if [[ -z "${TASK_ID// }" ]]; then
  echo "task_id must not be empty" >&2
  exit 1
fi

RUN_ID="$(resolve_run_id)"
if [[ -z "$RUN_ID" ]]; then
  echo "orca-dispatch-existing.sh: no Run bound to this terminal — refusing to dispatch task=$TASK_ID." >&2
  run_scope_hint >&2
  exit 1
fi

# A --retry-of dispatch shares $TASK_ID with the dispatch it is replacing.
# register_dispatch_and_reap below will append a SECOND ledger row for that
# same taskId and start a second reaper — but mark_ledger (orca-reap-task.sh)
# matches ledger rows by taskId alone, with no dispatchId filter. If the OLD
# dispatch's reaper is still alive (worker-stop kills the terminal's PTY, not
# the reaper process watching it), its next settle/timeout write clobbers
# BOTH rows sharing this taskId — including this retry's, even while it is
# actively succeeding. Stop that old reaper first so only one is ever live
# per task.
if [[ -n "$RETRY_OF" ]]; then
  OLD_PID_FILE="$ORCH/reapers/${TASK_ID}.pid"
  if [[ -f "$OLD_PID_FILE" ]]; then
    OLD_PID="$(cat "$OLD_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
      echo "orca-dispatch-existing.sh: stopped the prior reaper (pid=$OLD_PID) for task=$TASK_ID before retry." >&2
    fi
  fi
fi

echo "Dispatching existing task=$TASK_ID to ROLE=$ROLE${RETRY_OF:+ (retry-of=$RETRY_OF)}…"
WD_OUT="$(dispatch_task_to_role "$ROLE" "$TASK_ID" "$RUN_ID" "$RETRY_OF")" || {
  echo "orca-dispatch-existing.sh: worker-start failed for ROLE=$ROLE task=$TASK_ID — not guessing or retrying." >&2
  exit 1
}
HANDLE="${WD_OUT%%$'\t'*}"
DISPATCH_ID="${WD_OUT#*$'\t'}"

register_dispatch_and_reap "$LEDGER_FILE" "$TASK_ID" "$DISPATCH_ID" "$ROLE" "$HANDLE" "$NO_REAP" "$REAP_TIMEOUT_MS"

echo "Dispatched. task_id=$TASK_ID handle=$HANDLE dispatch_id=$DISPATCH_ID"
echo "  status: orca orchestration dispatch-show --task $TASK_ID --json"
echo "  optional block: .orca/orchestration/scripts/orca-wait-done.sh --role $ROLE --task $TASK_ID"
