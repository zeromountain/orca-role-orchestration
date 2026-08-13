#!/usr/bin/env bash
# Dispatch supervised Orca task to a role worker.
# Usage:
#   .orca/orchestration/scripts/orca-dispatch-role.sh <architect|executor|thrifty|fallback> --spec "..."
#   .orca/orchestration/scripts/orca-dispatch-role.sh architect --spec-file path.md [--deps '["task_xxx"]']
#
# Role tabs are ephemeral. After worker-start, a background reaper watches
# worker/dispatch status and releases (or closes) the worker tab on
# succeeded|failed (no manual step).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
ROLE=""
SPEC=""
SPEC_FILE=""
SCOPE=""
DONE_DEF=""
DEPS="[]"
AFTER=""
WAIT_DONE=0
NO_REAP=0
PERSIST=0
TIMEOUT_MS=900000
REAP_TIMEOUT_MS=3600000
WORKTREE="active"
PROJECT_NAME="$(basename "$ROOT")"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"

usage() {
  cat <<'EOF'
Usage:
  orca-dispatch-role.sh <architect|executor|thrifty|ui|reviewer|fallback|debater_{claude,codex,grok,gemini}> "text"
  orca-dispatch-role.sh <role> --spec "text"
  orca-dispatch-role.sh <role> --spec-file file.md [--deps '["task_id"]']
  orca-dispatch-role.sh <role> "…" [--scope path,path] [--done "verify cmd"]
  orca-dispatch-role.sh <role> --spec "…" [--wait] [--no-reap] [--persist] [--timeout-ms N]

By default a background reaper auto-closes the worker tab when the dispatch
completes or fails (no coordinator action required).

  (positional)  The first argument after <role> that does not start with "-"
              is absorbed as the spec body — an alternative to --spec for the
              common case. --spec still wins if both are given.
  --scope     Comma-separated path list appended to the spec as "Allowed scope: …"
  --done      Verification command(s) appended to the spec as "Done: …"
  --wait      Also block on orca-wait-done.sh, pinned to THIS dispatch's own
              task id (--task) so it can only complete on this task's own
              message, never a leftover from an unrelated flow (optional;
              reaper still runs unless --no-reap)
  --no-reap   Disable automatic background close (tabs will linger unless closed elsewhere)
  --persist   Keep the worker tab open after worker_done (implies --no-reap).
              For multi-round flows (debate) where the caller closes tabs itself.
  --timeout-ms  Timeout for --wait only (default 900000). Reaper default lifetime 1h.
  --after task_id[,task_id...]  This task becomes ready only once every listed
              task completes (shorthand for --deps '["task_id",...]'; the two
              are mutually exclusive).
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi
ROLE="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC="${2:?}"; shift 2 ;;
    --spec-file) SPEC_FILE="${2:?}"; shift 2 ;;
    --scope) SCOPE="${2:?}"; shift 2 ;;
    --done) DONE_DEF="${2:?}"; shift 2 ;;
    --deps) DEPS="${2:?}"; shift 2 ;;
    --after) AFTER="${2:?}"; shift 2 ;;
    --wait) WAIT_DONE=1; shift ;;
    --no-reap) NO_REAP=1; shift ;;
    --persist) PERSIST=1; NO_REAP=1; shift ;;
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown: $1" >&2; exit 1 ;;
    *)
      # Positional spec absorption: only the FIRST such argument is taken
      # (a second bare word is very likely a typo, not a second spec) — an
      # explicit --spec always wins over it if both are somehow given.
      if [[ -z "$SPEC" ]]; then
        SPEC="$1"
      else
        echo "Unknown: $1 (spec already set — did you mean --spec?)" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ ! -f "$HANDLES_FILE" ]]; then
  echo "Missing $HANDLES_FILE — run .orca/orchestration/scripts/orca-bootstrap-roles.sh first" >&2
  exit 1
fi

validate_role "$ROLE" || exit 1
if [[ -n "$SPEC_FILE" ]]; then SPEC="$(cat "$SPEC_FILE")"; fi
if [[ -z "${SPEC// }" ]]; then echo "--spec, --spec-file, or a positional spec is required" >&2; exit 1; fi

if [[ -n "$SCOPE" ]]; then SPEC="$SPEC
Allowed scope: $SCOPE"; fi
if [[ -n "$DONE_DEF" ]]; then SPEC="$SPEC
Done: $DONE_DEF"; fi

if [[ -n "$AFTER" ]]; then
  if [[ "$DEPS" != "[]" ]]; then
    echo "--after and --deps are mutually exclusive" >&2
    exit 1
  fi
  DEPS="$(python3 -c '
import json, sys
print(json.dumps([t.strip() for t in sys.argv[1].split(",") if t.strip()]))
' "$AFTER")"
fi

# Project context for seed() if recreate path runs.
# Read as a bare global by create_role in orca-roles-lib.sh.
# shellcheck disable=SC2034
WORKTREE="$(python3 - "$HANDLES_FILE" <<'PY' 2>/dev/null || echo active
import json, sys
with open(sys.argv[1]) as stream:
    print(json.load(stream).get("worktree") or "active")
PY
)"
if [[ -f "$ROOT/package.json" ]]; then
  PROJECT_NAME="$(python3 - "$ROOT/package.json" "$PROJECT_NAME" <<'PY' 2>/dev/null || echo "$PROJECT_NAME"
import json, sys
with open(sys.argv[1]) as stream:
    print(json.load(stream).get("name") or sys.argv[2])
PY
)"
fi
if [[ -f "$ROOT/AGENTS.md" ]]; then
  CONSTRAINTS="Read and follow AGENTS.md in the project root."
elif [[ -f "$ROOT/CLAUDE.md" ]]; then
  CONSTRAINTS="Read and follow CLAUDE.md in the project root."
else
  # Read as a bare global by seed() in orca-roles-lib.sh.
  # shellcheck disable=SC2034
  CONSTRAINTS="Follow repository conventions; never commit secrets."
fi

HANDLE="$(ensure_terminal "$ROLE")"

# Dead-man watchdog registration (Task 2): completely generic and
# debate-agnostic — this script does not know or care what ORCA_ROLE_LOCK_FILE
# means (today only orca-debate.sh sets it, via its own exported env var,
# inherited by this process since orca-debate-round.sh calls this script as a
# child). If a --persist caller has an active lock context, register our
# resolved handle so that caller's watchdog knows to close it if the caller
# ever stops proving it is alive. A missing/absent lock context, or a
# non-persist dispatch, is a normal no-op — most dispatches have neither.
if [[ "$PERSIST" -eq 1 && -n "${ORCA_ROLE_LOCK_FILE:-}" && -f "$ORCA_ROLE_LOCK_FILE" ]]; then
  lock_register_handle "$ORCA_ROLE_LOCK_FILE" "$HANDLE" \
    || echo "(warn) could not register $HANDLE with lock $ORCA_ROLE_LOCK_FILE — the watchdog owning that lock will not know about this handle" >&2
fi

# Gate (Task 2, fix round 3): confirm the worker's actual screen BEFORE
# task-create, not after. Round 1 gated only right before --inject, with
# `orca orchestration task-create` already having run — every failed live
# debate traced back to exactly that ordering: seed() (called inside
# ensure_terminal above) sends the seed text and the model starts
# responding to it (the seed explicitly asks it to acknowledge its role),
# so the terminal is legitimately BUSY, not ready, for however long that
# response takes. The old inject-side gate would refuse a busy-but-working
# seat, and by then task-create had already run — the script's own
# now-removed error message admitted it: "task_id=... was already created
# and is now stranded undispatched". A stranded task is never dispatched
# and never appears in a ledger row, so `dispatch-show` returns null,
# `dispatch_status` reads that as unknown, and the round polls to a full
# timeout believing the seat might still respond. Gating here means a
# refusal costs nothing — no task exists yet to strand — and
# terminal_wait_ready's own BUSY handling (see orca-roles-lib.sh) now
# extends its patience specifically for "the model is responding", rather
# than refusing a seat that is doing exactly what the seed asked it to do.
# No elapsed-time floor is passed (unlike ensure_terminal's own gate before
# seeding): this call site does not know a genuine creation timestamp for
# $HANDLE (it may have just been created moments ago by ensure_terminal
# above, which already applied that floor once before seeding, or it may
# be a long-warm terminal from a prior dispatch), and re-flooring from
# "now" on every ordinary dispatch would add pure, unrequested latency to
# the six pre-existing roles' hot path for no safety benefit.
echo "Waiting for worker tui-idle…"
orca terminal wait --terminal "$HANDLE" --for tui-idle --timeout-ms 90000 --json >/dev/null || true
AGENT_CLI="$(role_meta "$ROLE" | cut -f3)"
if ! terminal_wait_ready "$HANDLE" "$AGENT_CLI"; then
  echo "orca-dispatch-role.sh: $HANDLE for role=$ROLE never showed a ready screen — refusing to dispatch. No task was created; re-run once the terminal is confirmed ready, or clear its screen by hand if it is sitting on a first-run prompt (see the screen dump above)." >&2
  exit 1
fi

# Resolve the Run scope ONCE (see resolve_run_id in orca-roles-lib.sh): the
# same value must reach the tail block, task-create AND dispatch, or a
# rebinding mid-script would split one dispatch across two Runs — or worse,
# tell the worker to report into a different Run than the task lives in.
# Empty is a legal result and keeps the pre-2026-07-31 behaviour; the refusal
# path below is what tells the caller when that fallback is why nothing
# happened.
RUN_ID="$(resolve_run_id)"
RUN_ARGS=()
if [[ -n "$RUN_ID" ]]; then
  RUN_ARGS=(--run "$RUN_ID")
else
  # Deadlock fix (RC-1): dispatching with no Run bound structurally dooms
  # this task's own worker_done — dispatch_tail_block's RUN SCOPE block
  # (the instruction that tells the worker to add --run to its OWN `send`)
  # is only emitted when RUN_ID is non-empty, so without one the worker's
  # eventual worker_done is refused (legacy_read_only) even when the task
  # itself succeeded. Measured in production: dispatch-ledger.jsonl rows
  # stuck at status=dispatched for days, each with a reaper log reading
  # "timeout after 3600000ms — not closing (task may still be running)" —
  # dispatch-show never moves because nothing ever reports done. Refusing
  # here, before task-create, costs nothing (no task exists yet to strand)
  # and matches the readiness-gate ordering above for the same reason.
  echo "orca-dispatch-role.sh: no Run bound to this terminal — refusing to dispatch ROLE=$ROLE." >&2
  echo "Dispatching now would create a task whose worker_done can never be delivered." >&2
  run_scope_hint >&2
  exit 1
fi

# The spec no longer carries a tail contract (RUN SCOPE/AUTO-CLOSE/STAY-OPEN
# are gone — see dispatch_tail_block's removal note in orca-roles-lib.sh):
# `worker-start` below injects the worker's dispatch identity itself, and
# self-close is now forbidden regardless of --persist. --persist's only
# remaining effect is skipping the reaper (below), so the coordinator (or the
# debate driver) decides close-vs-reuse instead of the worker's own spec text.
FULL_SPEC="$(build_role_spec "$ROLE" "$SPEC" "$ORCH/personas")"

echo "Creating task for ROLE=$ROLE → $HANDLE${RUN_ID:+ (run=$RUN_ID)}"
CREATE_JSON="$(orca orchestration task-create ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} --deps "$DEPS" \
  --task-title "$ROLE dispatch" --display-name "[$ROLE]" --spec "$FULL_SPEC" --json)"
TASK_ID="$(parse_task_id "$CREATE_JSON")"
if [[ -z "$TASK_ID" ]]; then
  echo "Failed to parse task id:" >&2
  echo "$CREATE_JSON" >&2
  # The single most likely cause when RUN_ID resolved empty: the call fell
  # through to the read-only legacy coordinator. Say so instead of leaving
  # the caller with raw JSON.
  warn_if_legacy_read_only "$CREATE_JSON" "task-create for ROLE=$ROLE"
  exit 1
fi
echo "task_id=$TASK_ID"

# No second readiness gate here — fix round 3 moved the one gate to before
# task-create above specifically so a refusal never strands a task. Adding
# a redundant check back here would re-run the classifier for no benefit:
# nothing touches the terminal between the gate above and this point except
# the task-create call itself (an orchestration-side API call, not a
# terminal write), so the terminal's readiness cannot regress in between.
# dispatch_task_to_role (orca-roles-lib.sh) runs its own gate too — cheap and
# necessary for its OTHER callers (orca-dispatch-dag.sh,
# orca-dispatch-existing.sh) that have no pre-task-create gate of their own.
#
# worker-start replaces the old `dispatch --to --inject` (see
# references/orca-contract-2026-08-13.md S1-b/S1-c): it attaches our
# pre-created, custom-argv role terminal to the task and injects the
# worker's own dispatch identity — measured live, the worker's eventual
# worker_done needs no RUN SCOPE reminder to land correctly.
echo "Starting worker…"
WD_OUT="$(dispatch_task_to_role "$ROLE" "$TASK_ID" "$RUN_ID")" || {
  echo "orca-dispatch-role.sh: worker-start failed for ROLE=$ROLE task=$TASK_ID — not guessing or retrying." >&2
  exit 1
}
# dispatch_task_to_role calls ensure_terminal internally too and can return a
# DIFFERENT handle than the one resolved above (the terminal died between
# then and now and was transparently recreated) — re-sync HANDLE from its
# output, exactly like orca-dispatch-dag.sh / orca-dispatch-existing.sh
# already do. Registering the reaper against the stale handle would poll a
# terminal that's already gone while the real, live worker leaks untracked.
HANDLE="${WD_OUT%%$'\t'*}"
DISPATCH_ID="${WD_OUT#*$'\t'}"

register_dispatch_and_reap "$LEDGER_FILE" "$TASK_ID" "$DISPATCH_ID" "$ROLE" "$HANDLE" "$NO_REAP" "$REAP_TIMEOUT_MS"

if [[ "$WAIT_DONE" -eq 1 ]]; then
  # --task pins this wait to the dispatch we just created (Task 4): without
  # it, a leftover worker_done from an unrelated flow (e.g. a multi-round
  # debate, which deliberately never drains its own worker_done backlog)
  # would be the first message orca-wait-done.sh sees, and --role would then
  # resolve the close target from handles.json by role name rather than from
  # that message — closing this role's real, still-running tab and
  # reporting THIS task done on the strength of someone else's completion.
  echo "Also blocking on wait-done…"
  exec "$HERE/orca-wait-done.sh" --timeout-ms "$TIMEOUT_MS" --role "$ROLE" --task "$TASK_ID"
fi

echo "Dispatched. task_id=$TASK_ID handle=$HANDLE"
echo "  status: orca orchestration dispatch-show --task $TASK_ID --json"
echo "  optional block: .orca/orchestration/scripts/orca-wait-done.sh --role $ROLE --task $TASK_ID"
