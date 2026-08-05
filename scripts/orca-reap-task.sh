#!/usr/bin/env bash
# Automatically close a worker terminal when its dispatch finishes.
#
# Polls `orca orchestration dispatch-show` (does NOT consume inbox messages).
# On status completed|failed → `orca terminal close --tab`.
#
# Intended to be started in the background by orca-dispatch-role.sh so close
# is automatic without the coordinator running wait-done or close-role.
#
# Usage:
#   orca-reap-task.sh --task task_xxx --handle term_yyy [--role thrifty] [--timeout-ms N]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"

TASK_ID=""
HANDLE=""
ROLE=""
TIMEOUT_MS=3600000   # 1h default reaper lifetime
POLL_MS=5000

usage() {
  cat <<'EOF'
Usage:
  orca-reap-task.sh --task <task_id> --handle <term_*> [--role ROLE] [--timeout-ms N] [--poll-ms N]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_ID="${2:?}"; shift 2 ;;
    --handle) HANDLE="${2:?}"; shift 2 ;;
    --role) ROLE="${2:?}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    --poll-ms) POLL_MS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$TASK_ID" || -z "$HANDLE" ]]; then
  usage
  exit 1
fi

close_handle() {
  # → 0 closed or already gone, 1 close genuinely failed
  local h="$1" rc
  close_terminal "$h"
  rc=$?
  case "$rc" in
    0) echo "reap: closed $h"; return 0 ;;
    1) echo "reap: $h already gone"; return 0 ;;
    *) echo "reap: CLOSE FAILED for $h (Orca unreachable?)" >&2; return 1 ;;
  esac
}

mark_ledger() {
  # $1=status, remaining args are extra k=v fields
  local status="$1"
  shift
  ledger_update "$LEDGER_FILE" "$TASK_ID" "status=$status" "reaped=true" "$@"
}

# Give up loudly. Deliberately does NOT close: when the status is unreadable the
# task may still be running, and killing a live worker is worse than leaving it.
# The non-zero exit plus the ledger row is what makes the leak visible
# (surfaced by orca-status.sh) instead of silent.
reap_fail() {
  local reason="$1"
  echo "reap: FAILED — $reason (task=$TASK_ID handle=$HANDLE role=${ROLE:-})" >&2
  echo "reap: worker tab $HANDLE may still be open — check orca-status.sh" >&2
  mark_ledger "reap_failed" "reason=$reason"
  exit 1
}

# Prints the dispatch status, or __parse_error__ when the response could not be
# read at all. Collapsing those two into "unknown" is what let a JSON shape
# change silently burn the whole timeout and exit 0.
dispatch_status() {
  local out
  out="$(orca orchestration dispatch-show --task "$TASK_ID" --json 2>/dev/null)" \
    || { printf '__parse_error__'; return 0; }
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("__parse_error__")
    raise SystemExit(0)
r = d.get("result") or d
disp = r.get("dispatch") or r
status = disp.get("status") if isinstance(disp, dict) else None
print(status or "__parse_error__")
' 2>/dev/null || printf '__parse_error__'
}

echo "reap: watching task=$TASK_ID handle=$HANDLE role=${ROLE:-} timeout-ms=$TIMEOUT_MS"
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
POLL_S="$(python3 -c 'import sys; print(max(0.1, int(sys.argv[1])/1000))' "$POLL_MS")"
PARSE_ERRORS=0
MAX_PARSE_ERRORS=5

while true; do
  NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  ELAPSED=$((NOW_MS - START_MS))
  if [[ "$ELAPSED" -ge "$TIMEOUT_MS" ]]; then
    reap_fail "timeout after ${ELAPSED}ms without a terminal status"
  fi

  STATUS="$(dispatch_status)"
  case "$STATUS" in
    completed|failed)
      echo "reap: task $TASK_ID status=$STATUS — closing worker"
      if close_handle "$HANDLE"; then
        mark_ledger "closed"
        exit 0
      fi
      reap_fail "dispatch $STATUS but the worker tab could not be closed"
      ;;
    __parse_error__)
      PARSE_ERRORS=$((PARSE_ERRORS + 1))
      if [[ "$PARSE_ERRORS" -ge "$MAX_PARSE_ERRORS" ]]; then
        reap_fail "dispatch-show unreadable ${PARSE_ERRORS}x (output shape changed?)"
      fi
      sleep "$POLL_S"
      ;;
    dispatched|pending|ready|running|"")
      PARSE_ERRORS=0
      sleep "$POLL_S"
      ;;
    *)
      # unknown future statuses: keep polling until timeout
      PARSE_ERRORS=0
      sleep "$POLL_S"
      ;;
  esac
done
