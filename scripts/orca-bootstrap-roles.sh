#!/usr/bin/env bash
# Bootstrap role workers: architect (Opus 4.8), executor (Sol), thrifty (Grok 4.5),
# fallback (agy Gemini 3.5 Flash Medium).
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

seed "$ARCH_HANDLE" architect "Claude Opus 4.8" "$(role_fallback_body architect)"
seed "$SOL_HANDLE" executor "GPT-5.6 Sol" "$(role_fallback_body executor)"
seed "$GROK_HANDLE" thrifty "Grok 4.5" "$(role_fallback_body thrifty)"
seed "$FALLBACK_HANDLE" fallback "Antigravity Gemini 3.5 Flash (Medium)" "$(role_fallback_body fallback)"

python3 - "$HANDLES_FILE" "$ARCH_HANDLE" "$SOL_HANDLE" "$GROK_HANDLE" "$FALLBACK_HANDLE" "$WORKTREE" <<'PY'
import json, sys, datetime
path, arch, sol, grok, fallback, wt = sys.argv[1:7]
data = {
  "version": 1,
  "updatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "worktree": wt,
  "architect": arch,
  "executor": sol,
  "thrifty": grok,
  "fallback": fallback,
  "roles": {
    "architect": {"handle": arch, "title": "role-opus-architect", "model": "claude-opus-4-8", "agent": "claude"},
    "executor":  {"handle": sol,  "title": "role-sol-executor",   "model": "gpt-5.6-sol",     "agent": "codex"},
    "thrifty":   {"handle": grok, "title": "role-grok-thrifty",   "model": "grok-4.5",        "agent": "grok"},
    "fallback":  {
      "handle": fallback, "title": "role-agy-fallback",
      "model": "Gemini 3.5 Flash (Medium)", "agent": "antigravity", "cli": "agy",
    },
  },
  "limit_failover": {
    "enabled": True,
    "target_role": "fallback",
    "model": "Gemini 3.5 Flash (Medium)",
    "script": ".orca/orchestration/scripts/orca-fallback-on-limit.sh",
  },
  "routing_ssot": ".orca/orchestration/roles.yaml",
  "playbook": ".orca/orchestration/PLAYBOOK.md",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"Wrote {path}")
print(json.dumps(data["roles"], indent=2))
PY

echo "Done. Use PLAYBOOK.md + handles.json for dispatch."
echo "After each worker_done: .orca/orchestration/scripts/orca-close-role.sh <role>"
echo "Limit failover: .orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec \"...\""
