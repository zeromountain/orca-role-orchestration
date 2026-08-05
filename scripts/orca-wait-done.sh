#!/usr/bin/env bash
# Wait for supervised orchestration completion and auto-close the worker tab.
#
# Why: bare `orca orchestration check --wait` leaves agent sessions idle after
# worker_done. Coordinators forget the follow-up close. This wrapper closes the
# completing worker's tab (PTY) automatically.
#
# Task filter (--task): `orca orchestration check` has no per-task selector —
# it hands back whatever message of the requested --types shows up next,
# regardless of whose task it is. A multi-round debate leaves its own
# worker_done messages queued behind it (the debate path deliberately never
# drains its inbox: draining via `check` would consume messages belonging to
# any concurrent flow, which is worse than the pollution — see
# templates/SCRIPTS.md). Without --task, this script acts on the FIRST
# message it receives no matter whose task it is: a leftover debate
# worker_done then closes an unrelated terminal and reports the wrong task
# done. Pass --task <id> to make this script ignore any message whose
# payload task id does not match: that message is left un-acted-on (not
# closed on, not reported as the awaited completion) and the wait keeps
# polling under the ORIGINAL overall --timeout-ms, not a fresh one per
# message. orca-dispatch-role.sh --wait passes --task automatically, using
# the task id it just created, so it can only ever complete on its own
# message. A non-matching message is still consumed by the underlying
# `check` call that returned it — there is no CLI verb to selectively leave
# one message unread while consuming another out of the same batch — it is
# simply not acted on; its type/task/from/subject is logged to stderr so
# that information is never silently discarded.
#
# Single-waiter assumption: this script assumes exactly ONE
# orca-wait-done.sh (or orca-dispatch-role.sh --wait) process is polling at
# a time. Two concurrent waiters would race for the same `check` messages —
# whichever call happens to receive a given message decides its fate, and
# the other waiter would never see it (and would keep waiting, believing
# nothing has arrived). This is NOT supported; run waits sequentially.
#
# Usage:
#   .orca/orchestration/scripts/orca-wait-done.sh
#   .orca/orchestration/scripts/orca-wait-done.sh --timeout-ms 900000
#   .orca/orchestration/scripts/orca-wait-done.sh --no-close          # wait only
#   .orca/orchestration/scripts/orca-wait-done.sh --role thrifty --task task_abc123   # prefer role handle; always pin --task
#   .orca/orchestration/scripts/orca-wait-done.sh --types worker_done,escalation
#   .orca/orchestration/scripts/orca-wait-done.sh --task task_abc123  # only complete on this task
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
TASK_FILTER=""

usage() {
  cat <<'EOF'
Usage:
  orca-wait-done.sh [--timeout-ms N] [--types t1,t2] [--role ROLE] [--task ID]
                    [--no-close] [--close-on-escalation]

Waits on orca orchestration check --wait for worker_done/escalation/decision_gate.
On worker_done: auto-closes the worker terminal tab (--tab) unless --no-close.
Prints the check JSON to stdout (same shape as orca orchestration check --json)
once per poll — with --task, a poll that returns only non-matching messages
still prints its JSON and then polls again, so more than one JSON blob may
appear across a single run.

--task ID   Only act on a message whose payload task id equals ID. Any other
            message received meanwhile is left alone (not closed on, not
            reported done, but still consumed by the underlying `check` —
            there is no way to leave just that one message unread) and the
            wait continues under the ORIGINAL overall --timeout-ms. Without
            --task, behavior is unchanged: the first message received is
            acted on regardless of its task id (this is what makes --task
            backward compatible for existing callers).
            NOTE: only one orca-wait-done.sh should run at a time — see the
            file header ("Single-waiter assumption").
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    --types) TYPES="${2:?}"; shift 2 ;;
    --role) ROLE_HINT="${2:?}"; shift 2 ;;
    --task) TASK_FILTER="${2:?}"; shift 2 ;;
    --no-close) NO_CLOSE=1; shift ;;
    --close-on-escalation) CLOSE_ON_ESCALATION=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

now_ms() {
  # Wall clock in integer milliseconds. Always prints a number (falls back
  # to 0 on any failure) so a `$(( DEADLINE_MS - $(now_ms) ))` arithmetic
  # expansion downstream can never abort the script on a non-numeric value.
  python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 0
}

MSG_TYPE=""
FROM_HANDLE=""
TASK_ID=""
SUBJECT=""

# Resolved once and shared by both branches below — `check` is Run-scoped like
# task-create/dispatch (see resolve_run_id in orca-roles-lib.sh). Empty keeps
# the pre-2026-07-31 call shape exactly.
RUN_ID="$(resolve_run_id)"
RUN_ARGS=()
if [[ -n "$RUN_ID" ]]; then
  RUN_ARGS=(--run "$RUN_ID")
fi

if [[ -z "$TASK_FILTER" ]]; then
  # ---------------------------------------------------------------------
  # No filter: the original single-shot behavior, with one addition — the
  # Run scope below. When RUN_ARGS is empty the emitted command is
  # byte-for-byte the original (Step 3 acceptance: existing callers must be
  # unaffected); when it is set, the call reaches the same Run that
  # orca-dispatch-role.sh created the task in, instead of the read-only
  # legacy coordinator.
  # ---------------------------------------------------------------------
  echo "Waiting (types=$TYPES timeout-ms=$TIMEOUT_MS)…" >&2
  CHECK_JSON="$(orca orchestration check ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} --wait --types "$TYPES" --timeout-ms "$TIMEOUT_MS" --json)"
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
print("COUNT=" + shlex.quote(str(count)))
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

  # A non-numeric COUNT (an unexpected API response shape) would abort this
  # script on `-eq` under set -e; treat it as "no messages" rather than
  # crashing the coordinator.
  if ! [[ "${COUNT:-0}" =~ ^[0-9]+$ ]]; then COUNT=0; fi
  if [[ "$COUNT" -eq 0 || -z "${MSG_TYPE:-}" ]]; then
    echo "No matching message (timeout/checkpoint). Worker not closed." >&2
    exit 0
  fi
  echo "Received type=$MSG_TYPE subject=$SUBJECT from=$FROM_HANDLE task=$TASK_ID" >&2
else
  # ---------------------------------------------------------------------
  # Task-filtered wait: poll under the ORIGINAL overall deadline, examining
  # every message a poll returns (never only the first — a `check` response
  # can carry several, e.g. a backlog of leftover debate worker_done
  # messages). A poll that returns messages but none matching TASK_FILTER is
  # NOT treated as done and NOT treated as a timeout: it loops again with
  # whatever time remains under TIMEOUT_MS. A poll that returns zero
  # messages is treated exactly as the no-filter path treats it (timeout or
  # checkpoint — see usage()): this script does not invent a retry-past-a-
  # checkpoint behavior that the no-filter path never had either.
  # ---------------------------------------------------------------------
  DEADLINE_MS=$(( $(now_ms) + TIMEOUT_MS ))
  while :; do
    REMAINING_MS=$(( DEADLINE_MS - $(now_ms) ))
    if [[ "$REMAINING_MS" -le 0 ]]; then
      echo "No matching message (timeout/checkpoint). Worker not closed." >&2
      exit 0
    fi

    echo "Waiting (types=$TYPES timeout-ms=$REMAINING_MS task=$TASK_FILTER)…" >&2
    CHECK_JSON="$(orca orchestration check ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} --wait --types "$TYPES" --timeout-ms "$REMAINING_MS" --json)"
    printf '%s\n' "$CHECK_JSON"

    eval "$(printf '%s' "$CHECK_JSON" | python3 -c '
import json, sys, shlex

task_filter = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
r = d.get("result") or d
msgs = r.get("messages") or []
if not isinstance(msgs, list):
    msgs = []
count = r.get("count")
if count is None:
    count = len(msgs)
print("COUNT=" + shlex.quote(str(count)))


def extract(m):
    payload = m.get("payload") or {}
    if isinstance(payload, str) and payload.strip():
        try:
            payload = json.loads(payload)
        except Exception:
            payload = {}
    if not isinstance(payload, dict):
        payload = {}
    return {
        "type": str(m.get("type") or ""),
        "from": str(m.get("from_handle") or m.get("from") or ""),
        "task": str(payload.get("taskId") or ""),
        "subject": str(m.get("subject") or ""),
    }


selected = None
skipped = []
for m in msgs:
    info = extract(m)
    if selected is None and info["task"] == task_filter:
        selected = info
    else:
        skipped.append(info)

if selected is None:
    print("MATCHED=0")
    print("MSG_TYPE=")
    print("FROM_HANDLE=")
    print("TASK_ID=")
    print("SUBJECT=")
else:
    print("MATCHED=1")
    print("MSG_TYPE=" + shlex.quote(selected["type"]))
    print("FROM_HANDLE=" + shlex.quote(selected["from"]))
    print("TASK_ID=" + shlex.quote(selected["task"]))
    print("SUBJECT=" + shlex.quote(selected["subject"]))

# Non-matching messages are never silently dropped from the record: each one
# is logged to stderr (type/task/from/subject) even though it was already
# consumed by the check call that returned it and cannot be un-consumed.
for s in skipped:
    sys.stderr.write(
        "  (skip) non-matching message type=%s task=%s from=%s subject=%s\n"
        % (s["type"], s["task"], s["from"], s["subject"])
    )
' "$TASK_FILTER")"

    if ! [[ "${COUNT:-0}" =~ ^[0-9]+$ ]]; then COUNT=0; fi
    if [[ "$COUNT" -eq 0 ]]; then
      echo "No matching message (timeout/checkpoint). Worker not closed." >&2
      exit 0
    fi
    if [[ "${MATCHED:-0}" -ne 1 ]]; then
      echo "Received $COUNT message(s), none for task=$TASK_FILTER — continuing to wait." >&2
      continue
    fi
    echo "Received type=$MSG_TYPE subject=$SUBJECT from=$FROM_HANDLE task=$TASK_ID" >&2
    break
  done
fi

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
# Fix round (whole-branch review, item 7): this used to fire
# `orca terminal close` fire-and-forget, log "may already be gone" on
# failure, and continue regardless — then mark_ledger below wrote
# status="closed" UNCONDITIONALLY on both branches, the identical silent-
# success lie an earlier task on this branch already removed from
# orca-reap-task.sh and orca-sweep-orphans.sh (which now both use
# terminal_close_and_verify + a 0/1/2 -> closed/close_failed/
# close_undetermined mapping — see orca-reap-task.sh's close_handle).
# terminal_close_and_verify (orca-roles-lib.sh, already sourced) already
# does the same "prefer --tab, fall back to a plain close" attempt this
# used to do manually, then RE-CHECKS instead of trusting the close call's
# own reported success.
CLOSE_STATUS="closed"
close_rc=0
terminal_close_and_verify "$CLOSE_HANDLE" || close_rc=$?
case "$close_rc" in
  0)
    echo "Closed $CLOSE_HANDLE (confirmed gone)" >&2
    CLOSE_STATUS="closed"
    ;;
  1)
    echo "Close FAILED for $CLOSE_HANDLE — still live after a close attempt" >&2
    CLOSE_STATUS="close_failed"
    ;;
  2)
    echo "Close for $CLOSE_HANDLE could not be confirmed (liveness undetermined)" >&2
    CLOSE_STATUS="close_undetermined"
    ;;
esac

# Mark ledger row (best-effort), with the HONEST status from above rather
# than a hardcoded "closed". Fix round (item 8): the old body did
# `with open(path, "w") as f: <rewrite all rows>` — a plain in-place open
# truncates the file the instant it is opened, before any row is written
# back, so a kill of this process in that window would zero
# dispatch-ledger.jsonl. Same temp-file + os.replace pattern
# orca-roles-lib.sh's lock_write documents and uses at length, and
# orca-reap-task.sh's own mark_ledger now also uses (byte-identical write
# mechanism; this script's row does not set "reaped" — that field records
# the background reap CYCLE having acted, which is not what this script
# is).
if [[ -n "$TASK_ID" && -f "$LEDGER_FILE" ]]; then
  python3 - "$LEDGER_FILE" "$TASK_ID" "$CLOSE_STATUS" <<'PY' 2>/dev/null || true
import json, os, sys, datetime, fcntl
path, tid, status = sys.argv[1:4]
rows = []
try:
    # Locked in addition to the existing temp+replace atomicity: this script
    # and orca-reap-task.sh's background reaper can both be watching the same
    # task, and two overlapping full-file read-modify-write cycles are a
    # lost-update race no matter how atomically each one lands on disk.
    with open(path + ".lock", "a+") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
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
                    row["status"] = status
                rows.append(row)
        tmp_path = path + ".tmp." + str(os.getpid())
        with open(tmp_path, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        os.replace(tmp_path, path)
except Exception:
    pass
PY
fi

# A close that did not take effect ($CLOSE_STATUS=close_failed/undetermined)
# still exits 0 here, matching orca-reap-task.sh's own completed/failed
# branch: this script's job is "did I learn my task's outcome", not "did the
# close mechanically verify" — the ledger status is the record of that,
# checked by orca-status.sh, not this exit code. (tests/debate.sh WCV1 pins
# this down explicitly: a close that never takes must not mark the ledger
# "closed", but the wait itself must still report success.)
exit 0
