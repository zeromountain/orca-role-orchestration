#!/usr/bin/env bash
# Bootstrap role workers: architect (Opus 4.8), executor (Sol), thrifty (Grok 4.5),
# fallback (agy Gemini 3.5 Flash Medium).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
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

create_role() {
  local title="$1" command="$2" role_key="$3"
  echo "→ Creating $title"
  local json handle
  json="$(orca terminal create --worktree "$WORKTREE" --title "$title" --command "$command" --json)"
  handle="$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
r=d.get("result") or d
h=r.get("handle") or (r.get("terminal") or {}).get("handle") or d.get("handle")
if not h:
    raise SystemExit("no handle in terminal create response")
print(h)
')"
  orca terminal rename --terminal "$handle" --title "$title" --json >/dev/null 2>&1 || true
  echo "  handle=$handle"
  printf '%s\t%s\n' "$role_key" "$handle"
}

wait_idle() {
  orca terminal wait --terminal "$1" --for tui-idle --timeout-ms 90000 --json >/dev/null 2>&1 \
    || echo "  (warn) tui-idle wait timed out for $1"
}

echo "Bootstrapping role workers (worktree=$WORKTREE project=$PROJECT_NAME)…"

ARCH_LINE="$(create_role "role-opus-architect" \
  'claude --model claude-opus-4-8 --dangerously-skip-permissions' architect)"
ARCH_HANDLE="${ARCH_LINE##*$'\t'}"

SOL_LINE="$(create_role "role-sol-executor" \
  'codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox' executor)"
SOL_HANDLE="${SOL_LINE##*$'\t'}"

GROK_LINE="$(create_role "role-grok-thrifty" \
  'grok --model grok-4.5 --permission-mode bypassPermissions' thrifty)"
GROK_HANDLE="${GROK_LINE##*$'\t'}"

FALLBACK_LINE="$(create_role "role-agy-fallback" \
  'agy --model "Gemini 3.5 Flash (Medium)" --dangerously-skip-permissions' fallback)"
FALLBACK_HANDLE="${FALLBACK_LINE##*$'\t'}"

wait_idle "$ARCH_HANDLE"
wait_idle "$SOL_HANDLE"
wait_idle "$GROK_HANDLE"
wait_idle "$FALLBACK_HANDLE"

CONSTRAINTS=""
if [[ -f "$ROOT/AGENTS.md" ]]; then
  CONSTRAINTS="Read and follow AGENTS.md in the project root."
elif [[ -f "$ROOT/CLAUDE.md" ]]; then
  CONSTRAINTS="Read and follow CLAUDE.md in the project root."
else
  CONSTRAINTS="Follow repository conventions; never commit secrets."
fi

persona_body() {
  # $1 = role key. Echo persona file content minus the H1 and the STANCE comment.
  # Return non-zero if the file is absent (caller falls back to a hardcoded one-liner).
  local role="$1" file="$OUT_DIR/personas/$role.md"
  [[ -f "$file" ]] || return 1
  grep -vE '^# |^<!-- STANCE:' "$file"
}

seed() {
  local handle="$1" role="$2" model="$3" fallback_body="$4" body
  if body="$(persona_body "$role")" && [[ -n "${body// }" ]]; then
    : # use full persona file
  else
    body="$fallback_body"
  fi
  orca terminal send --terminal "$handle" --text "$(cat <<EOF
You are ROLE=$role on model $model in an Orca multi-agent setup for $PROJECT_NAME.

$body

Project constraints:
$CONSTRAINTS
Never commit secrets (.env, keys, *.pem).
Model disagreement → project SSOT docs + current code win.

When you receive an Orca orchestration dispatch preamble, follow it exactly and send worker_done once with taskId+dispatchId.
Until then, acknowledge role and wait.
EOF
)" --enter --json >/dev/null
}

seed "$ARCH_HANDLE" architect "Claude Opus 4.8" \
  "Own architecture, judgment, high-risk review, long-horizon plans. Prefer plans/reviews over bulk implementation."
seed "$SOL_HANDLE" executor "GPT-5.6 Sol" \
  "Own hard implementation, terminal loops, verification, final integration. Execute approved plans end-to-end."
seed "$GROK_HANDLE" thrifty "Grok 4.5" \
  "Own small tickets, maps, research, prototypes, high-volume low-risk edits. Escalate design risk."
seed "$FALLBACK_HANDLE" fallback "Antigravity Gemini 3.5 Flash (Medium)" \
  "Rate/session-limit safety net. Continue interrupted tasks with smallest viable progress."

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
echo "Limit failover: .orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec \"...\""
