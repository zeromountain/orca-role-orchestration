#!/usr/bin/env bash
# Wait for supervised orchestration completion and auto-close the worker tab.
#
# Why: bare `orca orchestration check --wait` leaves agent sessions idle after
# worker_done. Coordinators forget the follow-up close. This wrapper closes the
# completing worker's tab (PTY) automatically.
#
# Usage:
#   .orca/orchestration/scripts/orca-wait-done.sh
#   .orca/orchestration/scripts/orca-wait-done.sh --timeout-ms 900000
#   .orca/orchestration/scripts/orca-wait-done.sh --no-close          # wait only
#   .orca/orchestration/scripts/orca-wait-done.sh --role thrifty      # prefer role handle
#   .orca/orchestration/scripts/orca-wait-done.sh --types worker_done,escalation
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"

TIMEOUT_MS=900000
TYPES="worker_done,escalation,decision_gate"
NO_CLOSE=0
ROLE_HINT=""
CLOSE_ON_ESCALATION=0

usage() {
  cat <<'EOF'
Usage:
  orca-wait-done.sh [--timeout-ms N] [--types t1,t2] [--role ROLE] [--no-close]
                    [--close-on-escalation]

Waits on orca orchestration check --wait for worker_done/escalation/decision_gate.
On worker_done: auto-closes the worker terminal tab (--tab) unless --no-close.
Prints the check JSON to stdout (same shape as orca orchestration check --json).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    --types) TYPES="${2:?}"; shift 2 ;;
    --role) ROLE_HINT="${2:?}"; shift 2 ;;
    --no-close) NO_CLOSE=1; shift ;;
    --close-on-escalation) CLOSE_ON_ESCALATION=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

echo "Waiting (types=$TYPES timeout-ms=$TIMEOUT_MS)…" >&2
CHECK_JSON="$(orca orchestration check --wait --types "$TYPES" --timeout-ms "$TIMEOUT_MS" --json)"
printf '%s\n' "$CHECK_JSON"

# Parse first message
eval "$(printf '%s' "$CHECK_JSON" | python3 -c '
import json, sys, shlex
d = json.load(sys.stdin)
r = d.get("result") or d
msgs = r.get("messages") or []
count = r.get("count")
if count is None:
    count = len(msgs) if isinstance(msgs, list) else 0
print(f"COUNT={count}")
if not msgs:
    print("MSG_TYPE=")
    print("FROM_HANDLE=")
    print("TASK_ID=")
    print("SUBJECT=")
    raise SystemExit(0)
m = msgs[0]
payload = m.get("payload") or {}
if isinstance(payload, str) and payload.strip():
    try:
        payload = json.loads(payload)
    except Exception:
        payload = {}
if not isinstance(payload, dict):
    payload = {}
print("MSG_TYPE=" + shlex.quote(str(m.get("type") or "")))
print("FROM_HANDLE=" + shlex.quote(str(m.get("from_handle") or m.get("from") or "")))
print("TASK_ID=" + shlex.quote(str(payload.get("taskId") or "")))
print("SUBJECT=" + shlex.quote(str(m.get("subject") or "")))
')"

if [[ "${COUNT:-0}" -eq 0 || -z "${MSG_TYPE:-}" ]]; then
  echo "No matching message (timeout/checkpoint). Worker not closed." >&2
  exit 0
fi

echo "Received type=$MSG_TYPE subject=$SUBJECT from=$FROM_HANDLE task=$TASK_ID" >&2

should_close=0
if [[ "$MSG_TYPE" == "worker_done" && "$NO_CLOSE" -eq 0 ]]; then
  should_close=1
elif [[ "$MSG_TYPE" == "escalation" && "$CLOSE_ON_ESCALATION" -eq 1 && "$NO_CLOSE" -eq 0 ]]; then
  should_close=1
fi

if [[ "$should_close" -ne 1 ]]; then
  if [[ "$MSG_TYPE" == "decision_gate" ]]; then
    echo "decision_gate — leaving worker open; reply then re-wait." >&2
  elif [[ "$MSG_TYPE" == "escalation" ]]; then
    echo "escalation — leaving worker open (use --close-on-escalation to force close)." >&2
  fi
  exit 0
fi

# Resolve close target: role hint → ledger → from_handle
CLOSE_HANDLE=""
if [[ -n "$ROLE_HINT" && -f "$HANDLES_FILE" ]]; then
  CLOSE_HANDLE="$(handles_get "$HANDLES_FILE" "$ROLE_HINT" || true)"
fi

if [[ -z "$CLOSE_HANDLE" && -n "$TASK_ID" && -f "$LEDGER_FILE" ]]; then
  CLOSE_HANDLE="$(python3 - "$LEDGER_FILE" "$TASK_ID" <<'PY'
import json, sys
path, tid = sys.argv[1:3]
handle = ""
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
            if row.get("taskId") == tid and row.get("handle"):
                handle = row["handle"]
except FileNotFoundError:
    pass
print(handle)
PY
)"
fi

if [[ -z "$CLOSE_HANDLE" ]]; then
  CLOSE_HANDLE="$FROM_HANDLE"
fi

if [[ -z "$CLOSE_HANDLE" || "$CLOSE_HANDLE" != term_* ]]; then
  echo "Could not resolve worker handle to close (from=$FROM_HANDLE role=$ROLE_HINT task=$TASK_ID)" >&2
  exit 0
fi

echo "Auto-closing completed worker tab: $CLOSE_HANDLE" >&2
# Prefer whole-tab close so the sub-session disappears from the sidebar
if orca terminal close --terminal "$CLOSE_HANDLE" --tab --json >/dev/null 2>&1 \
  || orca terminal close --terminal "$CLOSE_HANDLE" --json >/dev/null 2>&1; then
  echo "Closed $CLOSE_HANDLE" >&2
else
  echo "Close returned non-zero for $CLOSE_HANDLE (may already be gone)" >&2
fi

# Mark ledger row closed (best-effort)
if [[ -n "$TASK_ID" && -f "$LEDGER_FILE" ]]; then
  python3 - "$LEDGER_FILE" "$TASK_ID" <<'PY' 2>/dev/null || true
import json, sys, datetime
path, tid = sys.argv[1:3]
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
                row["closedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                row["status"] = "closed"
            rows.append(row)
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
except Exception:
    pass
PY
fi

exit 0
