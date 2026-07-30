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
  local h="$1" live_rc=0
  if [[ -z "$h" || "$h" != term_* ]]; then
    return 0
  fi
  # terminal_is_live's 3-state contract: 0 live / 1 definitely dead / 2 could
  # not determine. Only a definite dead short-circuits here — an
  # undetermined result must NOT be treated as "already gone" (the reap loop
  # decided to close based on the dispatch's own status, not on this check;
  # an inconclusive `orca terminal list` shouldn't override that). The close
  # attempt below is the same idempotent call already used for a
  # confirmed-live handle and already tolerates one that turns out to be
  # gone, so falling through on "undetermined" is safe either way.
  terminal_is_live "$h" 2>/dev/null || live_rc=$?
  if [[ "$live_rc" -eq 1 ]]; then
    echo "reap: $h already gone"
    return 0
  fi
  if [[ "$live_rc" -eq 2 ]]; then
    echo "reap: $h liveness undetermined (orca terminal list unavailable) — attempting close anyway"
  fi
  echo "reap: closing $h (tab)"
  # Task 3, Part B: this is the actual close path for ordinary (non-debate)
  # dispatch — the reaper started by orca-dispatch-role.sh for every
  # six-role dispatch that doesn't opt into --persist. It used to fire
  # `orca terminal close` fire-and-forget and log success unconditionally,
  # the same class of bug the controller ruling on Task 1's review flagged
  # for orca-sweep-orphans.sh. terminal_close_and_verify (orca-roles-lib.sh)
  # re-checks afterward instead of trusting the close call's own reported
  # success, so a close that silently fails is reported LOUDLY here rather
  # than as a plain "closed". Unlike the debate lock's breadcrumb (Task 3,
  # Part A), there is no lock file at all for an ordinary role dispatch —
  # this makes the failure visible in the reaper's own log, it does not by
  # itself give the orphan sweeper a new way to find this handle later.
  local verify_rc=0
  terminal_close_and_verify "$h" || verify_rc=$?
  case "$verify_rc" in
    0) echo "reap: closed $h (confirmed gone)" ;;
    1) echo "reap: ERROR — $h is STILL LIVE after a close attempt for task=$TASK_ID" ;;
    2) echo "reap: closed $h (close attempted; could not confirm it is gone — liveness undetermined)" ;;
  esac
}

mark_ledger() {
  local status="$1"
  [[ -f "$LEDGER_FILE" ]] || return 0
  python3 - "$LEDGER_FILE" "$TASK_ID" "$status" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, tid, status = sys.argv[1:4]
rows = []
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if row.get("taskId") == tid:
                row["status"] = status
                row["closedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                row["reaped"] = True
            rows.append(row)
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
except Exception:
    pass
PY
}

echo "reap: watching task=$TASK_ID handle=$HANDLE role=${ROLE:-} timeout-ms=$TIMEOUT_MS"
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
POLL_S="$(python3 -c "print(max(1, int($POLL_MS)/1000))")"

while true; do
  NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  ELAPSED=$((NOW_MS - START_MS))
  if [[ "$ELAPSED" -ge "$TIMEOUT_MS" ]]; then
    echo "reap: timeout after ${ELAPSED}ms — not closing (task may still be running)"
    exit 0
  fi

  STATUS="$(dispatch_status "$TASK_ID")"
  case "$STATUS" in
    completed|failed)
      echo "reap: task $TASK_ID status=$STATUS — closing worker"
      close_handle "$HANDLE"
      mark_ledger "closed"
      exit 0
      ;;
    dispatched|pending|ready|running|unknown|"")
      sleep "$POLL_S"
      ;;
    *)
      # unknown future statuses: keep polling until timeout
      sleep "$POLL_S"
      ;;
  esac
done
