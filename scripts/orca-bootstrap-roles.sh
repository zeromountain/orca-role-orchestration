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

ROLES="architect executor thrifty fallback"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) WORKTREE="${2:?}"; shift 2 ;;
    --project-name) PROJECT_NAME="${2:?}"; shift 2 ;;
    --roles) ROLES="$(printf '%s' "${2:?}" | tr ',' ' ')"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--worktree <selector>] [--project-name NAME] [--roles a,b]"
      echo "  --roles  subset to bootstrap (default: all four)"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

for r in $ROLES; do
  if ! role_meta "$r" >/dev/null 2>&1; then
    echo "Unknown role in --roles: $r" >&2
    exit 1
  fi
done

if ! command -v orca >/dev/null 2>&1; then
  echo "orca CLI not found on PATH" >&2
  exit 1
fi
if ! orca_reachable; then
  echo "Orca runtime not reachable. Open Orca and retry." >&2
  exit 1
fi

# Preflight the per-role CLIs. Without this a missing binary produces a tab that
# dies with "command not found", a soft tui-idle warning, and a recorded-but-dead
# handle — the first real dispatch then fails looking like an orchestration bug.
MISSING=""
for r in $ROLES; do
  cli="$(role_cli "$r")"
  if ! command -v "$cli" >/dev/null 2>&1; then
    MISSING="$MISSING  $r → $cli not on PATH"$'\n'
  fi
done
if [[ -n "$MISSING" ]]; then
  echo "Missing role CLIs:" >&2
  printf '%s' "$MISSING" >&2
  echo "Install them, or bootstrap a subset: --roles architect,executor" >&2
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

handles_set_meta "$HANDLES_FILE" \
  "worktree=$WORKTREE" \
  "project=$PROJECT_NAME" \
  "routing_ssot=.orca/orchestration/roles.yaml" \
  "playbook=.orca/orchestration/PLAYBOOK.md"

# ensure_terminal is create + wait-idle + seed + record, and it reuses a role's
# terminal when one is already live. That makes bootstrap idempotent and
# RESUMABLE: if role 3 fails, re-running finishes the job instead of rebuilding
# — and no rollback is needed, which would only destroy working terminals.
FAILED=""
for role in $ROLES; do
  if handle="$(ensure_terminal "$role")"; then
    echo "  $role → $handle"
  else
    echo "  $role → FAILED" >&2
    FAILED="$FAILED $role"
  fi
done

if [[ -n "$FAILED" ]]; then
  echo "Bootstrap incomplete for:$FAILED" >&2
  echo "Re-run this script to finish — roles already up are reused, not recreated." >&2
  exit 1
fi

echo "Wrote $HANDLES_FILE"
echo "Done. Use PLAYBOOK.md + handles.json for dispatch."
echo "After dispatch: worker tabs auto-close (background reaper + worker AUTO-CLOSE)."
echo "  Optional block for results: orca orchestration check --wait --types worker_done,escalation,decision_gate"
echo "Limit failover: .orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec \"...\""
