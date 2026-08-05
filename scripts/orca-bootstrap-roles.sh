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
ROLES_OPT=""
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
    --roles) ROLES_OPT="$(printf '%s' "${2:?}" | tr ',' ' ')"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--worktree <selector>] [--project-name NAME] [--roles a,b]"
      echo "  --roles  subset of the four primaries to bootstrap (default: all four)"
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

ROLES=(architect executor thrifty fallback)
if [[ -n "$ROLES_OPT" ]]; then
  ROLES=()
  for r in $ROLES_OPT; do
    case "$r" in
      architect|executor|thrifty|fallback) ROLES+=("$r") ;;
      *) echo "--roles must be a subset of architect,executor,thrifty,fallback (got: $r)" >&2; exit 1 ;;
    esac
  done
fi

if ! command -v orca >/dev/null 2>&1; then
  echo "orca CLI not found on PATH" >&2
  exit 1
fi
if ! orca_reachable; then
  echo "Orca runtime not reachable. Open Orca and retry." >&2
  exit 1
fi

# Preflight the per-role CLIs. Without this a missing binary produces a tab
# that dies with "command not found", a soft tui-idle warning, and a
# recorded-but-dead handle — the first real dispatch then fails looking like
# an orchestration bug instead of a missing install.
MISSING=""
for r in "${ROLES[@]}"; do
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

# Stamp/normalize handles.json BEFORE any role is created, so the per-role
# handles_set calls below (inside the create loop) always have a file to
# read-modify-write against, and so this metadata (routing_ssot, playbook,
# limit_failover) is present even if every subsequent role fails.
#
# Locked + atomic: this can race handles_set (same file, same lock name) if a
# fallback creation or a dispatch-triggered recreate runs concurrently with
# bootstrap — a plain open(path,"w") here would win-or-lose that race and
# silently drop whichever write finished second.
python3 - "$HANDLES_FILE" "$WORKTREE" <<'PY'
import datetime, fcntl, json, os, sys
path, worktree = sys.argv[1:3]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
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
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
PY

# Failure isolation (Task 1, defect C): the four primary roles are created,
# waited-on, and seeded in three separate PHASES (not one role fully
# end-to-end before the next starts) so all four terminals still boot
# concurrently on the all-succeed path, exactly as before this fix — only
# per-role handles_set is now pulled forward into the create phase, and every
# per-role call that can fail is explicitly guarded instead of a bare
# statement, so one role's failure can never abort the loop and strand
# already-created terminals unrecorded (which is exactly what happened when
# `seed` for role 2 died under `set -euo pipefail` with handles.json written
# only at the very end). ROLES/HANDLES are plain bash 3.2 indexed arrays —
# always exactly 4 elements, so expanding them under `set -u` is always safe;
# FAILURES is a plain accumulated string (not an array) specifically because
# it CAN be empty on the all-succeed path, and an empty array's "${arr[@]}"
# expansion aborts some bash 3.2 builds under `set -u`. ROLES itself is set
# above (default all four, or the --roles subset).
HANDLES=()
for _ in "${ROLES[@]}"; do HANDLES+=(""); done
FAILURES=""
FAIL_COUNT=0

n_roles=${#ROLES[@]}
i=0
while [[ "$i" -lt "$n_roles" ]]; do
  role="${ROLES[$i]}"
  title="$(role_meta "$role" | cut -f1)"
  cmd="$(role_launch_cmd "$role")"
  if handle="$(create_role "$title" "$cmd" "$role")"; then
    HANDLES[$i]="$handle"
    if ! handles_set "$HANDLES_FILE" "$role" "$handle"; then
      echo "bootstrap: handles_set failed to record handle=$handle for role=$role — terminal is live but NOT durably tracked in $HANDLES_FILE (see terminal-journal.jsonl); skipping wait/seed for this role" >&2
      HANDLES[$i]=""
      FAILURES="${FAILURES}  - $role: created (handle=$handle) but handles_set failed — terminal is live, untracked in $HANDLES_FILE, recorded in terminal-journal.jsonl
"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  else
    echo "bootstrap: create_role failed for role=$role — see terminal-journal.jsonl for the raw create response" >&2
    FAILURES="${FAILURES}  - $role: create_role failed — no terminal created
"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  i=$((i + 1))
done

i=0
while [[ "$i" -lt "$n_roles" ]]; do
  if [[ -n "${HANDLES[$i]}" ]]; then
    wait_idle "${HANDLES[$i]}"
  fi
  i=$((i + 1))
done

i=0
while [[ "$i" -lt "$n_roles" ]]; do
  role="${ROLES[$i]}"
  handle="${HANDLES[$i]}"
  if [[ -n "$handle" ]]; then
    model="$(role_meta "$role" | cut -f2)"
    if ! seed "$handle" "$role" "$model" "$(role_fallback_body "$role")"; then
      echo "bootstrap: seed failed for role=$role handle=$handle — handle is recorded in $HANDLES_FILE so it can still be closed/retried" >&2
      FAILURES="${FAILURES}  - $role: seed failed — handle=$handle IS recorded in $HANDLES_FILE (closable/retryable)
"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
  i=$((i + 1))
done

echo "Wrote $HANDLES_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "" >&2
  echo "Bootstrap completed with $FAIL_COUNT failure(s):" >&2
  printf '%s' "$FAILURES" >&2
  echo "Handles for every role that WAS created are already recorded in $HANDLES_FILE. Re-run bootstrap to retry — ensure_terminal-based dispatch reuses any handle already on file." >&2
  exit 1
fi

echo "Done. Use PLAYBOOK.md + handles.json for dispatch."
echo "After dispatch: worker tabs auto-close (background reaper + worker AUTO-CLOSE)."
echo "  Optional block for results: orca orchestration check --wait --types worker_done,escalation,decision_gate"
echo "Limit failover: .orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec \"...\""

# Run scope check — bootstrap itself needs no Run (it only creates terminals),
# but the very next thing the user does (dispatch) does. Warning here turns a
# silent legacy_read_only refusal later into a one-line heads-up now.
if [[ -z "$(resolve_run_id)" ]]; then
  echo
  echo "WARNING: no orchestration Run is bound — dispatch will be refused (legacy_read_only)." >&2
  echo "  orca orchestration run-create --objective \"$PROJECT_NAME roles\" --json" >&2
fi
