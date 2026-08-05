#!/usr/bin/env bash
# Automatically close a worker terminal when its dispatch finishes.
#
# Polls `orca orchestration dispatch-show` (does NOT consume inbox messages).
# On status completed|failed → `orca terminal close --tab`.
#
# Intended to be started in the background by orca-dispatch-role.sh so close
# is automatic without the coordinator running wait-done or close-role.
#
# Usage:
#   orca-reap-task.sh --task task_xxx --handle term_yyy [--role thrifty] [--timeout-ms N]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
# Read as a bare global by handles_get/ensure_terminal in orca-roles-lib.sh.
# shellcheck disable=SC2034
HANDLES_FILE="$ORCH/handles.json"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"

TASK_ID=""
HANDLE=""
ROLE=""
TIMEOUT_MS=3600000   # 1h default reaper lifetime
POLL_MS=5000

usage() {
  cat <<'EOF'
Usage:
  orca-reap-task.sh --task <task_id> --handle <term_*> [--role ROLE] [--timeout-ms N] [--poll-ms N]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_ID="${2:?}"; shift 2 ;;
    --handle) HANDLE="${2:?}"; shift 2 ;;
    --role) ROLE="${2:?}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    --poll-ms) POLL_MS="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$TASK_ID" || -z "$HANDLE" ]]; then
  usage
  exit 1
fi

close_handle() {
  local h="$1" live_rc=0
  if [[ -z "$h" || "$h" != term_* ]]; then
    return 0
  fi
  # terminal_is_live's 3-state contract: 0 live / 1 definitely dead / 2 could
  # not determine. Only a definite dead short-circuits here — an
  # undetermined result must NOT be treated as "already gone" (the reap loop
  # decided to close based on the dispatch's own status, not on this check;
  # an inconclusive `orca terminal list` shouldn't override that). The close
  # attempt below is the same idempotent call already used for a
  # confirmed-live handle and already tolerates one that turns out to be
  # gone, so falling through on "undetermined" is safe either way.
  terminal_is_live "$h" 2>/dev/null || live_rc=$?
  if [[ "$live_rc" -eq 1 ]]; then
    echo "reap: $h already gone"
    return 0
  fi
  if [[ "$live_rc" -eq 2 ]]; then
    echo "reap: $h liveness undetermined (orca terminal list unavailable) — attempting close anyway"
  fi
  echo "reap: closing $h (tab)"
  # Task 3, Part B: this is the actual close path for ordinary (non-debate)
  # dispatch — the reaper started by orca-dispatch-role.sh for every
  # six-role dispatch that doesn't opt into --persist. It used to fire
  # `orca terminal close` fire-and-forget and log success unconditionally,
  # the same class of bug the controller ruling on Task 1's review flagged
  # for orca-sweep-orphans.sh. terminal_close_and_verify (orca-roles-lib.sh)
  # re-checks afterward instead of trusting the close call's own reported
  # success, so a close that silently fails is reported LOUDLY here rather
  # than as a plain "closed". Unlike the debate lock's breadcrumb (Task 3,
  # Part A), there is no lock file at all for an ordinary role dispatch —
  # this makes the failure visible in the reaper's own log, it does not by
  # itself give the orphan sweeper a new way to find this handle later.
  local verify_rc=0
  terminal_close_and_verify "$h" || verify_rc=$?
  case "$verify_rc" in
    0) echo "reap: closed $h (confirmed gone)" ;;
    1) echo "reap: ERROR — $h is STILL LIVE after a close attempt for task=$TASK_ID" ;;
    2) echo "reap: closed $h (close attempted; could not confirm it is gone — liveness undetermined)" ;;
  esac
  # Fix round 1 (Finding 1): this function's own body used to end on the
  # `case` above, whose every branch is a bare `echo` — meaning
  # close_handle's return status was always 0 (an echo's own exit code)
  # regardless of $verify_rc, no matter how loudly the "STILL LIVE" line
  # above screamed. The caller then called mark_ledger "closed"
  # unconditionally, so a close terminal_close_and_verify itself detected
  # as having failed still landed as status:"closed" in
  # dispatch-ledger.jsonl — the exact silent-success pattern Part B exists
  # to eliminate, surviving in the one artifact that outlives the terminal
  # output. Returning $verify_rc here is what lets the caller pick a ledger
  # status that matches reality instead of always writing "closed".
  return "$verify_rc"
}

mark_ledger() {
  # $1=status. "closedAt"/"reaped" are written unconditionally regardless
  # of which status is passed — they record that the reap CYCLE acted on
  # this task at this moment, not that the close itself succeeded; only
  # the "status" string carries that distinction (see the close_handle
  # call site below for the three values this can now be: "closed",
  # "close_failed", "close_undetermined").
  #
  # Fix round (whole-branch review, item 8): this reaper is a `nohup`
  # background process that can be killed at any moment, and the old body
  # did `with open(path, "w") as f: <rewrite all rows>` — a plain in-place
  # open TRUNCATES the file the instant it is opened, before any row is
  # written back. A kill in that window zeroes dispatch-ledger.jsonl.
  # orca-roles-lib.sh's lock_write already documents and uses the fix at
  # length for the exact same reason: write to a temp file in the SAME
  # directory, then os.replace (atomic on a local filesystem) — a killed
  # writer leaves, at worst, a stray .tmp.<pid> file next to an untouched,
  # still-valid ledger.
  # $2.. = optional extra k=v fields (e.g. reason=... for reap_fail below).
  local status="$1"
  shift
  [[ -f "$LEDGER_FILE" ]] || return 0
  python3 - "$LEDGER_FILE" "$TASK_ID" "$status" "$@" <<'PY' 2>/dev/null || true
import json, os, sys, datetime, fcntl
path, tid, status = sys.argv[1:4]
extra = {}
for kv in sys.argv[4:]:
    k, _, v = kv.partition("=")
    extra[k] = v
rows = []
try:
    # Locked in addition to the existing temp+replace atomicity: this reaper
    # is one of potentially several running concurrently (one per in-flight
    # dispatch), and two overlapping full-file read-modify-write cycles are a
    # lost-update race regardless of how atomically each one lands — the
    # loser's os.replace still wins with a stale snapshot that is missing
    # whatever the other reaper (or a fresh dispatch's append) just wrote.
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
                    row["status"] = status
                    row["closedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                    row["reaped"] = True
                    row.update(extra)
                rows.append(row)
        tmp_path = path + ".tmp." + str(os.getpid())
        with open(tmp_path, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        os.replace(tmp_path, path)
except Exception:
    pass
PY
}

# Give up loudly. Deliberately does NOT close: when the status could not be
# read the task may still be running, and killing a live worker is worse than
# leaving it. The non-zero exit plus the ledger row is what makes the leak
# visible (surfaced by orca-status.sh) instead of silent.
reap_fail() {
  local reason="$1"
  echo "reap: FAILED — $reason (task=$TASK_ID handle=$HANDLE role=${ROLE:-})" >&2
  echo "reap: worker tab $HANDLE may still be open — check orca-status.sh" >&2
  mark_ledger "reap_failed" "reason=$reason"
  exit 1
}

# Shadows orca-roles-lib.sh's shared dispatch_status() for the rest of THIS
# script only (a later function definition wins in bash; the shared lib is
# still used unmodified by every other caller). The shared version collapses
# any read/parse failure to the single word "unknown", indistinguishable from
# a dispatch that is genuinely still pending — which is exactly what let a
# `dispatch-show` JSON-shape change poll silently to the 1h timeout below and
# exit 0 without ever closing the tab. __parse_error__ keeps that failure
# mode distinct so the loop can bound and escalate it instead.
dispatch_status() {
  local out
  out="$(orca orchestration dispatch-show --task "$1" --json 2>/dev/null)" \
    || { printf '__parse_error__'; return 0; }
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("__parse_error__")
    raise SystemExit(0)
r = d.get("result") or d
disp = r.get("dispatch") or r
status = disp.get("status") if isinstance(disp, dict) else None
print(status or "__parse_error__")
' 2>/dev/null || printf '__parse_error__'
}

echo "reap: watching task=$TASK_ID handle=$HANDLE role=${ROLE:-} timeout-ms=$TIMEOUT_MS"
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
POLL_S="$(python3 -c 'import sys; print(max(0.1, int(sys.argv[1])/1000))' "$POLL_MS")"
PARSE_ERRORS=0
MAX_PARSE_ERRORS=5

while true; do
  NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  ELAPSED=$((NOW_MS - START_MS))
  if [[ "$ELAPSED" -ge "$TIMEOUT_MS" ]]; then
    reap_fail "timeout after ${ELAPSED}ms without a terminal status"
  fi

  STATUS="$(dispatch_status "$TASK_ID")"
  case "$STATUS" in
    completed|failed)
      echo "reap: task $TASK_ID status=$STATUS — closing worker"
      # Fix round 1 (Finding 1): close_handle can now legitimately return
      # 1 (still live) or 2 (undetermined), not just 0 — never call it
      # bare under this script's `set -euo pipefail`, or a real close
      # failure would kill the reaper mid-cycle instead of reaching
      # mark_ledger at all. The `*)` arm is defensive only: close_handle's
      # own contract is 0/1/2, matching terminal_close_and_verify.
      close_rc=0
      close_handle "$HANDLE" || close_rc=$?
      case "$close_rc" in
        0) mark_ledger "closed" ;;
        1) mark_ledger "close_failed" ;;
        2) mark_ledger "close_undetermined" ;;
        *) mark_ledger "close_undetermined" ;;
      esac
      exit 0
      ;;
    __parse_error__)
      PARSE_ERRORS=$((PARSE_ERRORS + 1))
      if [[ "$PARSE_ERRORS" -ge "$MAX_PARSE_ERRORS" ]]; then
        reap_fail "dispatch-show unreadable ${PARSE_ERRORS}x (output shape changed?)"
      fi
      sleep "$POLL_S"
      ;;
    dispatched|pending|ready|running|unknown|"")
      PARSE_ERRORS=0
      sleep "$POLL_S"
      ;;
    *)
      # unknown future statuses: keep polling until timeout
      PARSE_ERRORS=0
      sleep "$POLL_S"
      ;;
  esac
done
