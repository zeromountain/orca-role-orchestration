#!/usr/bin/env bash
# Bootstrap the four primary role workers. Models come from orca-roles-lib.sh
# (role_meta / role_launch_cmd) — never hardcode them here.
# Tabs are ephemeral after supervised worker_done (coordinator closes; dispatch recreates).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
OUT_DIR="$ORCH"
HANDLES_FILE="$OUT_DIR/handles.json"
WORKTREE="active"
PROJECT_NAME="$(basename "$ROOT")"
if [[ -f "$ROOT/package.json" ]]; then
  PROJECT_NAME="$(python3 - "$ROOT/package.json" "$PROJECT_NAME" <<'PY' 2>/dev/null || echo "$PROJECT_NAME"
import json
import sys

with open(sys.argv[1]) as stream:
    print(json.load(stream).get("name") or sys.argv[2])
PY
)"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="${2:?}"; shift 2 ;;
    --project-name) PROJECT_NAME="${2:?}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--worktree <selector>] [--project-name NAME]"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

if ! command -v orca >/dev/null 2>&1; then
  echo "orca CLI not found on PATH" >&2
  exit 1
fi
if ! orca status --json 2>/dev/null | grep -q '"reachable": true'; then
  echo "Orca runtime not reachable. Open Orca and retry." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

CONSTRAINTS=""
if [[ -f "$ROOT/AGENTS.md" ]]; then
  CONSTRAINTS="Read and follow AGENTS.md in the project root."
elif [[ -f "$ROOT/CLAUDE.md" ]]; then
  CONSTRAINTS="Read and follow CLAUDE.md in the project root."
else
  CONSTRAINTS="Follow repository conventions; never commit secrets."
fi

echo "Bootstrapping role workers (worktree=$WORKTREE project=$PROJECT_NAME)…"

ARCH_HANDLE="$(create_role "$(role_meta architect | cut -f1)" "$(role_launch_cmd architect)")"
SOL_HANDLE="$(create_role "$(role_meta executor | cut -f1)" "$(role_launch_cmd executor)")"
GROK_HANDLE="$(create_role "$(role_meta thrifty | cut -f1)" "$(role_launch_cmd thrifty)")"
FALLBACK_HANDLE="$(create_role "$(role_meta fallback | cut -f1)" "$(role_launch_cmd fallback)")"

wait_idle "$ARCH_HANDLE"
wait_idle "$SOL_HANDLE"
wait_idle "$GROK_HANDLE"
wait_idle "$FALLBACK_HANDLE"

seed "$ARCH_HANDLE"     architect "$(role_meta architect | cut -f2)" "$(role_fallback_body architect)"
seed "$SOL_HANDLE"      executor  "$(role_meta executor  | cut -f2)" "$(role_fallback_body executor)"
seed "$GROK_HANDLE"     thrifty   "$(role_meta thrifty   | cut -f2)" "$(role_fallback_body thrifty)"
seed "$FALLBACK_HANDLE" fallback  "$(role_meta fallback  | cut -f2)" "$(role_fallback_body fallback)"

python3 - "$HANDLES_FILE" "$WORKTREE" <<'PY'
import json, os, sys, datetime
path, worktree = sys.argv[1:3]
data = {"version": 1, "worktree": worktree, "roles": {}}
if os.path.exists(path):
    try:
        loaded = json.load(open(path))
        if isinstance(loaded, dict):
            data = loaded
            data["worktree"] = worktree
    except Exception:
        pass
data.setdefault("roles", {})
data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
data["routing_ssot"] = ".orca/orchestration/roles.yaml"
data["playbook"] = ".orca/orchestration/PLAYBOOK.md"
data["limit_failover"] = {
    "enabled": True,
    "target_role": "fallback",
    "script": ".orca/orchestration/scripts/orca-fallback-on-limit.sh",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

handles_set "$HANDLES_FILE" architect "$ARCH_HANDLE"
handles_set "$HANDLES_FILE" executor  "$SOL_HANDLE"
handles_set "$HANDLES_FILE" thrifty   "$GROK_HANDLE"
handles_set "$HANDLES_FILE" fallback  "$FALLBACK_HANDLE"
echo "Wrote $HANDLES_FILE"

echo "Done. Use PLAYBOOK.md + handles.json for dispatch."
echo "After dispatch: worker tabs auto-close (background reaper + worker AUTO-CLOSE)."
echo "  Optional block for results: orca orchestration check --wait --types worker_done,escalation,decision_gate"
echo "Limit failover: .orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec \"...\""
