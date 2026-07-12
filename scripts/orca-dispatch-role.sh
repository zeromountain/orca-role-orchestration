#!/usr/bin/env bash
# Dispatch supervised Orca task to a role worker.
# Usage:
#   ./scripts/orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "..."
#   ./scripts/orca-dispatch-role.sh architect --spec-file path.md [--deps '["task_xxx"]']
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
HANDLES_FILE="$ORCH/handles.json"
ROLE=""
SPEC=""
SPEC_FILE=""
DEPS="[]"

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "text"
  orca-dispatch-role.sh <role> --spec-file file.md [--deps '["task_id"]']

fallback = Antigravity Gemini 3.5 Flash (Medium) for rate/session limits.
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi
ROLE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC="${2:?}"; shift 2 ;;
    --spec-file) SPEC_FILE="${2:?}"; shift 2 ;;
    --deps) DEPS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$HANDLES_FILE" ]]; then
  echo "Missing $HANDLES_FILE — run ./scripts/orca-bootstrap-roles.sh first" >&2
  exit 1
fi

case "$ROLE" in
  architect|executor|thrifty|fallback) ;;
  *) echo "role must be architect|executor|thrifty|fallback" >&2; exit 1 ;;
esac
if [[ -n "$SPEC_FILE" ]]; then SPEC="$(cat "$SPEC_FILE")"; fi
if [[ -z "${SPEC// }" ]]; then echo "--spec or --spec-file required" >&2; exit 1; fi

HANDLE="$(python3 - "$HANDLES_FILE" "$ROLE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
role=sys.argv[2]
h=(d.get("roles") or {}).get(role, {}).get("handle") or d.get(role)
if not h:
    raise SystemExit(f"no handle for role {role}")
print(h)
PY
)"

MODEL="$(python3 - "$HANDLES_FILE" "$ROLE" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    data = json.load(stream)
print(data["roles"][sys.argv[2]]["model"])
PY
)"
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
TASK_ID="$(printf '%s' "$CREATE_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);r=d.get("result") or d; print(r.get("id") or r.get("task_id") or "")')"
if [[ -z "$TASK_ID" ]]; then
  echo "Failed to parse task id:" >&2
  echo "$CREATE_JSON" >&2
  exit 1
fi
echo "task_id=$TASK_ID"

echo "Waiting for worker tui-idle…"
orca terminal wait --terminal "$HANDLE" --for tui-idle --timeout-ms 90000 --json >/dev/null || true

echo "Dispatching (inject)…"
orca orchestration dispatch --task "$TASK_ID" --to "$HANDLE" --inject --json
echo "Dispatched. Wait with:"
echo "  orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 900000 --json"
echo "  orca orchestration dispatch-show --task $TASK_ID --json"
