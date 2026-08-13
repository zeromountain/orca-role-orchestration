#!/usr/bin/env bash
# Wire a role DAG pattern into Orca task-create calls in one shot, dispatching
# only the first (dependency-free) step immediately. Later steps are created
# as blocked tasks (task-create --deps) — a step whose role depends on a
# PRIOR step's actual OUTPUT, not just "prior step done", cannot be
# statically pre-wired, so the coordinator dispatches each later step once
# `task-list --ready` shows it ready, via orca-dispatch-existing.sh.
#
# Patterns live in orca-roles-lib.sh's dag_pattern() — single source, next to
# role_meta(). templates/roles.yaml's `dags:` block restates them as prose
# for a human reader; nothing parses it.
#
# Usage:
#   orca-dispatch-dag.sh <plan-exec-review|ui|explore> "<goal>" [--no-reap]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"
NO_REAP=0
REAP_TIMEOUT_MS=3600000

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-dag.sh <plan-exec-review|ui|explore> "<goal>" [--no-reap]

Patterns:
  plan-exec-review   architect(plan) -> executor(impl) -> reviewer(gate)
  ui                 ui(draft) -> architect(approve) -> ui(impl) -> reviewer(review)
  explore            thrifty(read-only map) -> architect(plan) -> executor(impl)

Creates every step as an Orca task, wired with --deps so each step becomes
ready only once its predecessor completes. Dispatches (starts a worker for)
ONLY the first step now — later steps are created but left blocked. Once a
later step is ready:
  orca orchestration task-list --ready --json
  .orca/orchestration/scripts/orca-dispatch-existing.sh <task_id> <role>
EOF
}

if [[ $# -lt 2 ]]; then usage; exit 1; fi
PATTERN="$1"; GOAL="$2"; shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-reap) NO_REAP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$HANDLES_FILE" ]]; then
  echo "Missing $HANDLES_FILE — run .orca/orchestration/scripts/orca-bootstrap-roles.sh first" >&2
  exit 1
fi
if [[ -z "${GOAL// }" ]]; then
  echo "goal must not be empty" >&2
  exit 1
fi

STEPS="$(dag_pattern "$PATTERN")" || exit 1

# Refuse up front, same reasoning as orca-dispatch-role.sh: dispatching with
# no Run bound structurally dooms every step's worker_done, and refusing
# before any task-create runs costs nothing (nothing exists yet to strand).
RUN_ID="$(resolve_run_id)"
if [[ -z "$RUN_ID" ]]; then
  echo "orca-dispatch-dag.sh: no Run bound to this terminal — refusing to wire a DAG." >&2
  run_scope_hint >&2
  exit 1
fi
RUN_ARGS=(--run "$RUN_ID")

# Readiness gate for step 1's role, BEFORE any task-create runs — same
# reasoning, and the same bug, as orca-dispatch-role.sh's "fix round 3"
# (see its own comment): gating only inside dispatch_task_to_role, AFTER
# step 1's task-create has already run, strands that task with no worker
# and no ledger row the moment the terminal isn't ready. dispatch_task_to_role
# still re-gates before its own worker-start call — cheap on an
# already-live terminal, and it is what protects every OTHER caller
# (orca-dispatch-existing.sh) that has no pre-gate of its own.
STEP1_ROLE="$(printf '%s\n' "$STEPS" | head -1 | cut -f1)"
STEP1_HANDLE="$(ensure_terminal "$STEP1_ROLE")" || {
  echo "orca-dispatch-dag.sh: could not prepare a terminal for step 1 (role=$STEP1_ROLE) — refusing to wire a DAG. No task was created." >&2
  exit 1
}
STEP1_AGENT_CLI="$(role_meta "$STEP1_ROLE" | cut -f3)"
orca terminal wait --terminal "$STEP1_HANDLE" --for tui-idle --timeout-ms 90000 --json >/dev/null || true
if ! terminal_wait_ready "$STEP1_HANDLE" "$STEP1_AGENT_CLI"; then
  echo "orca-dispatch-dag.sh: $STEP1_HANDLE for role=$STEP1_ROLE never showed a ready screen — refusing to wire a DAG. No task was created." >&2
  exit 1
fi

PREV_TASK_ID=""
STEP_NUM=0
# A here-string (not a pipe) so the loop body runs in THIS shell — PREV_TASK_ID
# and STEP_NUM must survive past each iteration, which a piped `... | while`
# cannot do (subshell loses them on exit).
while IFS=$'\t' read -r ROLE SPEC_TEMPLATE; do
  [[ -z "$ROLE" ]] && continue
  STEP_NUM=$((STEP_NUM + 1))
  SPEC="${SPEC_TEMPLATE//\{goal\}/$GOAL}"
  FULL_SPEC="$(build_role_spec "$ROLE" "$SPEC" "$ORCH/personas")"
  if [[ -n "$PREV_TASK_ID" ]]; then
    DEPS="[\"$PREV_TASK_ID\"]"
  else
    DEPS="[]"
  fi

  CREATE_JSON="$(orca orchestration task-create "${RUN_ARGS[@]}" --deps "$DEPS" \
    --task-title "$ROLE dispatch (dag:$PATTERN step $STEP_NUM)" --display-name "[$ROLE]" \
    --spec "$FULL_SPEC" --json)"
  TASK_ID="$(parse_task_id "$CREATE_JSON")"
  if [[ -z "$TASK_ID" ]]; then
    echo "orca-dispatch-dag.sh: task-create failed at step $STEP_NUM (role=$ROLE):" >&2
    echo "$CREATE_JSON" >&2
    warn_if_legacy_read_only "$CREATE_JSON" "task-create for dag step $STEP_NUM"
    exit 1
  fi

  if [[ "$STEP_NUM" -eq 1 ]]; then
    echo "Dispatching step 1 (ROLE=$ROLE task=$TASK_ID, ready now)…" >&2
    WD_OUT="$(dispatch_task_to_role "$ROLE" "$TASK_ID" "$RUN_ID")" || {
      echo "orca-dispatch-dag.sh: worker-start failed for step 1 (role=$ROLE task=$TASK_ID)." >&2
      exit 1
    }
    HANDLE="${WD_OUT%%$'\t'*}"
    DISPATCH_ID="${WD_OUT#*$'\t'}"
    register_dispatch_and_reap "$LEDGER_FILE" "$TASK_ID" "$DISPATCH_ID" "$ROLE" "$HANDLE" "$NO_REAP" "$REAP_TIMEOUT_MS"
    echo "step_$STEP_NUM=$TASK_ID role=$ROLE status=dispatched"
  else
    echo "step_$STEP_NUM=$TASK_ID role=$ROLE status=blocked deps=$DEPS"
  fi

  PREV_TASK_ID="$TASK_ID"
done <<<"$STEPS"

echo >&2
echo "DAG wired: $STEP_NUM step(s), pattern=$PATTERN, run=$RUN_ID." >&2
echo "Poll readiness: orca orchestration task-list --ready --json" >&2
echo "Dispatch a ready step: .orca/orchestration/scripts/orca-dispatch-existing.sh <task_id> <role>" >&2
