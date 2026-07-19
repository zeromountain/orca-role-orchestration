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
  local h="$1"
  if [[ -z "$h" || "$h" != term_* ]]; then
    return 0
  fi
  if ! terminal_is_live "$h" 2>/dev/null; then
    echo "reap: $h already gone"
    return 0
  fi
  echo "reap: closing $h (tab)"
  if orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1 \
    || orca terminal close --terminal "$h" --json >/dev/null 2>&1; then
    echo "reap: closed $h"
  else
    echo "reap: close non-zero for $h (ok if already gone)"
  fi
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

dispatch_status() {
  orca orchestration dispatch-show --task "$TASK_ID" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown")
    raise SystemExit(0)
r = d.get("result") or d
disp = r.get("dispatch") or r
print(disp.get("status") or "unknown")
' 2>/dev/null || echo "unknown"
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

  STATUS="$(dispatch_status)"
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
