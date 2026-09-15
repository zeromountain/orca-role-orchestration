#!/usr/bin/env bash
# Runtime script tests (R1–R30). Exit 0 only if all assert.
#
# Uses tests/fake-orca/orca as a PATH shim — no real Orca runtime needed.
# Every case installs the scaffold into a tmp project first and runs the
# scripts from their INSTALLED path, because runtime scripts self-locate via
# ORCH="$HERE/..". So each case is also an end-to-end check that what the
# installer emits is runnable.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/scripts/install-to-project.sh"
FAKE_DIR="$ROOT/tests/fake-orca"
chmod +x "$INSTALL" "$FAKE_DIR/orca"

pass=0
fail=0
assert() {
  local name="$1"
  shift
  if eval "$*"; then
    echo "  PASS  $name"
    pass=$((pass + 1))
  else
    echo "  FAIL  $name"
    fail=$((fail + 1))
  fi
}

tmproot="$(mktemp -d)"
trap 'rm -rf "$tmproot"' EXIT
export PATH="$FAKE_DIR:$PATH"
# codex_trust_ensure (orca-roles-lib.sh) writes to $CODEX_HOME/config.toml
# unconditionally whenever a codex-backed role is created — a real, global,
# user-owned file by default, regardless of whether `orca` itself is faked.
# Sandbox it so test runs never touch the developer's actual ~/.codex.
export CODEX_HOME="$tmproot/codex-home"
mkdir -p "$CODEX_HOME"

# The terminal-readiness gate and seed-marker retry knobs (orca-roles-lib.sh)
# default to real-CLI-boot-time scale (60s / 300s ceilings). The fake CLI
# answers `terminal read`/`terminal send` instantly, so there is nothing to
# wait out — these just make the suite run in seconds instead of minutes.
export ROLE_READY_TIMEOUT_SECONDS=5
export ROLE_READY_POLL_INTERVAL_SECONDS=1
export ROLE_READY_MIN_ELAPSED_SECONDS=0
export ROLE_BUSY_TIMEOUT_SECONDS=5
export ROLE_SEED_MARKER_RETRIES=1
export ROLE_SEED_MARKER_INTERVAL_SECONDS=0

# new_project <name> → echoes the scripts dir; sets STATE/PROJ globals
PROJ=""
STATE=""
SCRIPTS=""
new_project() {
  PROJ="$tmproot/$1"
  mkdir -p "$PROJ"
  "$INSTALL" --project-root "$PROJ" --project-name "$1" >"$tmproot/$1.install.log" 2>&1
  SCRIPTS="$PROJ/.orca/orchestration/scripts"
  OR="$PROJ/.orca/orchestration/or"
  STATE="$tmproot/$1.state"
  # Same layout the fake creates on first call — tests write here beforehand.
  mkdir -p "$STATE/sends" "$STATE/preview" "$STATE/status" "$STATE/fail" "$STATE/screen"
  touch "$STATE/calls.log" "$STATE/terminals"
  export FAKE_ORCA_STATE="$STATE"
}

calls_matching() { grep -c -- "$1" "$STATE/calls.log" 2>/dev/null | tr -d ' '; }
live_titled() { grep -c -- "$1" "$STATE/terminals" 2>/dev/null | tr -d ' '; }
ledger_status() {
  python3 - "$PROJ/.orca/orchestration/dispatch-ledger.jsonl" "$1" <<'PY' 2>/dev/null || echo "__none__"
import json, sys
path, tid = sys.argv[1:3]
out = "__none__"
with open(path) as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("taskId") == tid:
            out = row.get("status") or ""
print(out)
PY
}
ledger_rows() {
  python3 - "$PROJ/.orca/orchestration/dispatch-ledger.jsonl" <<'PY' 2>/dev/null || echo 0
import json, sys
n = 0
with open(sys.argv[1]) as stream:
    for line in stream:
        if line.strip():
            try:
                json.loads(line)
            except Exception:
                continue
            n += 1
print(n)
PY
}
seed_ledger_row() {
  # $1=task $2=handle $3=role
  local f="$PROJ/.orca/orchestration/dispatch-ledger.jsonl"
  mkdir -p "$(dirname "$f")"
  printf '{"taskId":"%s","dispatchId":"disp_x","role":"%s","handle":"%s","status":"dispatched"}\n' \
    "$1" "$3" "$2" >>"$f"
}

echo "=== tests/runtime.sh (tmp=$tmproot) ==="

# --- R1 bootstrap happy path (expected GREEN) ---
echo "R1 bootstrap happy path"
new_project r1
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r1.log" 2>&1
r1_rc=$?
H="$PROJ/.orca/orchestration/handles.json"
assert R1_exit0 "[[ $r1_rc -eq 0 ]]"
assert R1_four_creates "[[ \"\$(calls_matching 'terminal create')\" -eq 4 ]]"
assert R1_title_architect "grep -q role-fable-architect \"$STATE/calls.log\""
assert R1_title_executor "grep -q role-astra-executor \"$STATE/calls.log\""
assert R1_title_thrifty "grep -q role-grok-thrifty \"$STATE/calls.log\""
assert R1_title_fallback "grep -q role-agy-fallback \"$STATE/calls.log\""
assert R1_handles_parse "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \"$H\""
assert R1_architect_model "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"roles\"][\"architect\"][\"model\"]==\"claude-fable-5-1\" else 1)' \"$H\""
assert R1_four_live "[[ \"\$(live_titled role-)\" -eq 4 ]]"
# A bootstrapped worker and a dispatch-recreated one must be told the same
# model string — both paths route through ensure_terminal/role_meta now.
arch_handle="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["roles"]["architect"]["handle"])' "$H" 2>/dev/null || echo none)"
assert R1_seed_model_id "grep -q 'claude-fable-5-1' \"$STATE/sends/$arch_handle\""

# --- R2 reaper closes on completed (expected GREEN) ---
echo "R2 reaper closes on completed"
new_project r2
printf 'term_99\trole-grok-thrifty\n' >>"$STATE/terminals"
seed_ledger_row task_r2 term_99 thrifty
echo completed >"$STATE/status/task_r2"
"$SCRIPTS/orca-reap-task.sh" --task task_r2 --handle term_99 --poll-ms 100 --timeout-ms 3000 \
  >"$tmproot/r2.log" 2>&1
r2_rc=$?
assert R2_exit0 "[[ $r2_rc -eq 0 ]]"
assert R2_one_close "[[ \"\$(calls_matching 'terminal close')\" -eq 1 ]]"
assert R2_close_tab "grep -q -- '--tab' \"$STATE/calls.log\""
assert R2_terminal_gone "[[ \"\$(live_titled term_99)\" -eq 0 ]]"
assert R2_ledger_closed "[[ \"\$(ledger_status task_r2)\" == closed ]]"

# --- R3 reaper vs malformed dispatch-show (RED until Tier 1.1) ---
echo "R3 reaper vs malformed dispatch-show  [regression: bug A]"
new_project r3
printf 'term_98\trole-grok-thrifty\n' >>"$STATE/terminals"
seed_ledger_row task_r3 term_98 thrifty
echo garbage >"$STATE/fail/dispatch-show"
"$SCRIPTS/orca-reap-task.sh" --task task_r3 --handle term_98 --poll-ms 100 --timeout-ms 2000 \
  >"$tmproot/r3.log" 2>&1
r3_rc=$?
assert R3_nonzero_exit "[[ $r3_rc -ne 0 ]]"
assert R3_ledger_reap_failed "[[ \"\$(ledger_status task_r3)\" == reap_failed ]]"
assert R3_no_false_close "[[ \"\$(ledger_status task_r3)\" != closed ]]"

# --- R4 liveness probe unreadable → must still close (RED until Tier 1.2/1.3) ---
# A `terminal list` hiccup must not be read as "already gone". The close is the
# whole point of the reaper, so an unknown liveness result means attempt it
# anyway — a redundant close is free, a skipped one leaks a billable session.
# `terminal_close_and_verify` (orca-roles-lib.sh) then re-checks liveness to
# confirm the close actually took: with `terminal list` still broken, that
# confirmation is itself impossible, so the honest ledger status is
# "close_undetermined", not "closed" — the terminal really is gone here (the
# close call itself succeeds), the script just cannot prove it.
echo "R4 close when liveness probe is unreadable  [regression: bug B]"
new_project r4
printf 'term_97\trole-astra-executor\n' >>"$STATE/terminals"
seed_ledger_row task_r4 term_97 executor
echo completed >"$STATE/status/task_r4"
: >"$STATE/fail/terminal-list"   # daemon hiccup: `terminal list` exits 1
"$SCRIPTS/orca-reap-task.sh" --task task_r4 --handle term_97 --poll-ms 100 --timeout-ms 3000 \
  >"$tmproot/r4.log" 2>&1
r4_rc=$?
assert R4_exit0 "[[ $r4_rc -eq 0 ]]"
assert R4_closed_anyway "[[ \"\$(calls_matching 'terminal close')\" -ge 1 ]]"
assert R4_terminal_gone "[[ \"\$(live_titled term_97)\" -eq 0 ]]"
assert R4_ledger_undetermined "[[ \"\$(ledger_status task_r4)\" == close_undetermined ]]"

# --- R4b close genuinely fails → visible in the ledger, not the exit code ---
# orca-reap-task.sh deliberately exits 0 once a dispatch status was
# successfully determined (completed/failed), regardless of how the close
# itself went — the ledger status (closed/close_failed/close_undetermined) is
# the failure signal for this path, not the process exit code. R3's timeout/
# parse-error path is the one that escalates via exit 1; this is a different,
# later failure mode where the reap CYCLE completed but the close did not.
echo "R4b close genuinely fails  [regression]"
new_project r4b
printf 'term_96\trole-astra-executor\n' >>"$STATE/terminals"
seed_ledger_row task_r4b term_96 executor
echo completed >"$STATE/status/task_r4b"
: >"$STATE/fail/terminal-close"  # every close attempt exits 1
"$SCRIPTS/orca-reap-task.sh" --task task_r4b --handle term_96 --poll-ms 100 --timeout-ms 3000 \
  >"$tmproot/r4b.log" 2>&1
r4b_rc=$?
assert R4b_exit0 "[[ $r4b_rc -eq 0 ]]"
assert R4b_ledger_close_failed "[[ \"\$(ledger_status task_r4b)\" == close_failed ]]"
assert R4b_terminal_still_live "[[ \"\$(live_titled term_96)\" -eq 1 ]]"

# --- R5 concurrent ledger writers (RED until Tier 1.4) ---
# orca-dispatch-role.sh starts one background reaper PER dispatch, so N in-flight
# dispatches means N concurrent full-file read-modify-write cycles over the same
# dispatch-ledger.jsonl with no lock. Every writer must keep every other row.
echo "R5 concurrent ledger writers  [regression: bug C]"
new_project r5
R5_N=8
i=0
while [[ $i -lt $R5_N ]]; do
  printf 'term_9%s\trole-grok-thrifty\n' "$i" >>"$STATE/terminals"
  seed_ledger_row "task_r5_$i" "term_9$i" thrifty
  echo completed >"$STATE/status/task_r5_$i"
  i=$((i + 1))
done
# Pad so each read-modify-write takes long enough to overlap the others — a
# long-lived project accumulates rows like this anyway.
i=0
while [[ $i -lt 500 ]]; do
  seed_ledger_row "task_pad_$i" "term_pad_$i" thrifty
  i=$((i + 1))
done
i=0
while [[ $i -lt $R5_N ]]; do
  "$SCRIPTS/orca-reap-task.sh" --task "task_r5_$i" --handle "term_9$i" \
    --poll-ms 100 --timeout-ms 3000 >"$tmproot/r5.$i.log" 2>&1 &
  i=$((i + 1))
done
wait
assert R5_all_rows_survive "[[ \"\$(ledger_rows)\" -eq $((500 + R5_N)) ]]"
r5_closed=0
i=0
while [[ $i -lt $R5_N ]]; do
  if [[ "$(ledger_status "task_r5_$i")" == closed ]]; then r5_closed=$((r5_closed + 1)); fi
  i=$((i + 1))
done
assert R5_all_marks_survive "[[ $r5_closed -eq $R5_N ]]"
assert R5_pad_untouched "[[ \"\$(ledger_status task_pad_0)\" == dispatched ]]"

# --- R6 fallback vs corrupt handles.json (RED until Tier 1.4) ---
echo "R6 fallback vs corrupt handles.json  [regression]"
new_project r6
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r6.boot.log" 2>&1
assert R6_setup_one_fallback "[[ \"\$(live_titled role-agy-fallback)\" -eq 1 ]]"
# Simulate a reader hitting handles.json mid-rewrite (non-atomic write today).
printf '{"version": 1, "roles": {"archite' >"$PROJ/.orca/orchestration/handles.json"
"$SCRIPTS/orca-fallback-on-limit.sh" --from term_1 --spec "continue the work" \
  >"$tmproot/r6.log" 2>&1
assert R6_still_one_fallback "[[ \"\$(live_titled role-agy-fallback)\" -eq 1 ]]"

# --- R7 orca-status.sh reports health and surfaces leaks ---
echo "R7 orca-status.sh"
new_project r7
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r7.boot.log" 2>&1
"$SCRIPTS/orca-status.sh" >"$tmproot/r7.ok.log" 2>&1
r7_ok=$?
assert R7_healthy_exit0 "[[ $r7_ok -eq 0 ]]"
assert R7_reports_roles "grep -q architect \"$tmproot/r7.ok.log\""
assert R7_reports_live "grep -q live \"$tmproot/r7.ok.log\""
# A reaper that gave up must be visible, not silent.
seed_ledger_row task_r7 term_1 thrifty
ledger_file="$PROJ/.orca/orchestration/dispatch-ledger.jsonl"
python3 - "$ledger_file" <<'PY'
import json, sys
path = sys.argv[1]
rows = []
with open(path) as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        if row.get("taskId") == "task_r7":
            row["status"] = "reap_failed"
        rows.append(row)
with open(path, "w") as stream:
    for row in rows:
        stream.write(json.dumps(row) + "\n")
PY
"$SCRIPTS/orca-status.sh" >"$tmproot/r7.leak.log" 2>&1
r7_leak=$?
assert R7_leak_exit1 "[[ $r7_leak -ne 0 ]]"
assert R7_leak_named "grep -q reap_failed \"$tmproot/r7.leak.log\""

# Regression: a "released" row (native worker-release succeeded) must be
# treated as settled, same as "closed" — not flagged as a leak forever.
# Caught by hand while wiring worker-release in: the old filter only
# excluded the literal string "closed".
seed_ledger_row task_r7_released term_2 thrifty
python3 - "$ledger_file" <<PY
import json
path = "$ledger_file"
rows = []
with open(path) as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        if row.get("taskId") == "task_r7_released":
            row["status"] = "released"
        rows.append(row)
with open(path, "w") as stream:
    for row in rows:
        stream.write(json.dumps(row) + "\n")
PY
"$SCRIPTS/orca-status.sh" >"$tmproot/r7.released.log" 2>&1
assert R7_released_not_leak "! grep -q task_r7_released \"$tmproot/r7.released.log\""

# --- R8 roles.local.json overrides a role's binding ---
# The common first-install failure: no Grok subscription. Repointing `thrifty`
# must change the launch command, the recorded model, and which binary the
# preflight demands — without forking the scripts.
echo "R8 roles.local.json override"
new_project r8
cat >"$PROJ/.orca/orchestration/roles.local.json" <<'JSON'
{
  "thrifty": {
    "model": "claude-sonnet-5",
    "launch_command": "claude --model claude-sonnet-5 --dangerously-skip-permissions"
  }
}
JSON
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r8.log" 2>&1
r8_rc=$?
H8="$PROJ/.orca/orchestration/handles.json"
assert R8_exit0 "[[ $r8_rc -eq 0 ]]"
assert R8_launch_overridden "grep -q 'claude --model claude-sonnet-5' \"$STATE/calls.log\""
assert R8_model_recorded "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"roles\"][\"thrifty\"][\"model\"]==\"claude-sonnet-5\" else 1)' \"$H8\""
assert R8_default_role_intact "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"roles\"][\"architect\"][\"model\"]==\"claude-fable-5-1\" else 1)' \"$H8\""
assert R8_no_grok_launch "! grep -q 'grok --model grok-4.6' \"$STATE/calls.log\""
# The installer must never clobber this user-owned file.
"$INSTALL" --project-root "$PROJ" --project-name r8 >"$tmproot/r8.reinstall.log" 2>&1
assert R8_survives_upgrade "grep -q claude-sonnet-5 \"$PROJ/.orca/orchestration/roles.local.json\""
"$INSTALL" --project-root "$PROJ" --project-name r8 --reset >"$tmproot/r8.reset.log" 2>&1
assert R8_survives_reset "grep -q claude-sonnet-5 \"$PROJ/.orca/orchestration/roles.local.json\""

# --- R9 reaper detects a stalled worker (frozen screen) but never closes ----
# it — Orca's contract forbids releasing a worker on idle/timeout state
# alone (see references/orca-contract-2026-08-13.md). The reaper now only
# REPORTS "stalled" and keeps polling; the overall --timeout-ms backstop is
# what still escalates (reap_failed) a worker that genuinely never settles.
# Tight idle knobs + a short overall timeout so the test still runs in ~1s.
echo "R9 reaper detects a stalled worker but does not close it (contract fix)"
new_project r9
printf 'term_r9\trole-grok-thrifty\n' >>"$STATE/terminals"
seed_ledger_row task_r9 term_r9 thrifty
printf '%s\n' "❯ " >"$STATE/screen/term_r9"
"$SCRIPTS/orca-reap-task.sh" --task task_r9 --handle term_r9 --role thrifty \
  --poll-ms 50 --timeout-ms 3000 \
  --idle-grace-ms 0 --idle-probe-ms 50 --idle-strikes 3 \
  >"$tmproot/r9.log" 2>&1
r9_rc=$?
assert R9_nonzero_exit "[[ $r9_rc -ne 0 ]]"
assert R9_ledger_reap_failed "[[ \"\$(ledger_status task_r9)\" == reap_failed ]]"
assert R9_never_closed_stalled "[[ \"\$(ledger_status task_r9)\" != closed_stalled ]]"
assert R9_terminal_still_live "[[ \"\$(live_titled term_r9)\" -eq 1 ]]"
assert R9_no_close_call "[[ \"\$(calls_matching 'terminal close')\" -eq 0 ]]"
assert R9_log_says_stalled "grep -q stalled \"$tmproot/r9.log\""
assert R9_log_says_not_closing "grep -q 'not closing' \"$tmproot/r9.log\""

# --- R10 reaper notices a self-closed terminal without waiting out the ------
# --- full reap timeout (the worker followed AUTO-CLOSE after a refused -----
# --- worker_done, but dispatch-show never moved off its prior status) ------
echo "R10 reaper vs a worker that already closed its own tab"
new_project r10
seed_ledger_row task_r10 term_r10_gone thrifty
# Deliberately never added to $STATE/terminals: terminal_is_live reports 1
# (definitely absent) for a handle that never appears in `terminal list`.
"$SCRIPTS/orca-reap-task.sh" --task task_r10 --handle term_r10_gone --role thrifty \
  --poll-ms 50 --timeout-ms 10000 \
  --idle-grace-ms 0 --idle-probe-ms 100 --idle-strikes 3 \
  >"$tmproot/r10.log" 2>&1
r10_rc=$?
assert R10_exit0 "[[ $r10_rc -eq 0 ]]"
assert R10_ledger_closed "[[ \"\$(ledger_status task_r10)\" == closed ]]"
assert R10_no_close_call "[[ \"\$(calls_matching 'terminal close')\" -eq 0 ]]"

# --- R11 idle detection never fires on a screen that keeps changing --------
# (false-positive guard): content that differs every poll, even while it also
# matches a CLI's positive "ready" pattern on every single read, must never
# accumulate a strike streak. This is the core safety property RC-2 depends
# on — a model that is still actually generating must never be killed.
echo "R11 idle detection ignores a genuinely changing screen"
new_project r11
printf 'term_r11\trole-grok-thrifty\n' >>"$STATE/terminals"
seed_ledger_row task_r11 term_r11 thrifty
: >"$STATE/screen/term_r11.dynamic"
"$SCRIPTS/orca-reap-task.sh" --task task_r11 --handle term_r11 --role thrifty \
  --poll-ms 50 --timeout-ms 1500 \
  --idle-grace-ms 0 --idle-probe-ms 100 --idle-strikes 3 \
  >"$tmproot/r11.log" 2>&1
r11_rc=$?
assert R11_reap_failed_not_stalled "[[ \"\$(ledger_status task_r11)\" == reap_failed ]]"
assert R11_never_stalled "[[ \"\$(ledger_status task_r11)\" != closed_stalled ]]"
assert R11_terminal_still_live "[[ \"\$(live_titled term_r11)\" -eq 1 ]]"
assert R11_nonzero_exit "[[ $r11_rc -ne 0 ]]"

# --- R12 awaiting_reply suppresses idle detection ---------------------------
# A worker left open on a decision_gate/escalation (orca-wait-done.sh marks
# the ledger row "awaiting_reply" — see its own comment) is deliberately
# idle, waiting on the COORDINATOR. Same frozen screen as R9, but the idle
# probe must never count it: the run should reach the ordinary timeout path
# (reap_failed), not the idle fast path (closed_stalled).
echo "R12 awaiting_reply suppresses idle detection"
new_project r12
printf 'term_r12\trole-grok-thrifty\n' >>"$STATE/terminals"
f="$PROJ/.orca/orchestration/dispatch-ledger.jsonl"
mkdir -p "$(dirname "$f")"
printf '{"taskId":"task_r12","dispatchId":"disp_x","role":"thrifty","handle":"term_r12","status":"awaiting_reply"}\n' >>"$f"
printf '%s\n' "❯ " >"$STATE/screen/term_r12"
"$SCRIPTS/orca-reap-task.sh" --task task_r12 --handle term_r12 --role thrifty \
  --poll-ms 50 --timeout-ms 1000 \
  --idle-grace-ms 0 --idle-probe-ms 100 --idle-strikes 3 \
  >"$tmproot/r12.log" 2>&1
r12_rc=$?
assert R12_nonzero_exit "[[ $r12_rc -ne 0 ]]"
assert R12_reap_failed "[[ \"\$(ledger_status task_r12)\" == reap_failed ]]"
assert R12_never_stalled "[[ \"\$(ledger_status task_r12)\" != closed_stalled ]]"
assert R12_terminal_still_live "[[ \"\$(live_titled term_r12)\" -eq 1 ]]"

# --- R13 dispatch refuses to run with no Run bound --------------------------
# fake-orca has no "orchestration run-current" case, so it falls through to
# its `*)` handler (exit 64) and resolve_run_id soft-fails to empty — the
# same shape a real, older/unbound Orca terminal produces. Dispatching a task
# whose worker_done can never be delivered (see RUN SCOPE in
# orca-roles-lib.sh) must now be refused before task-create ever runs.
echo "R13 dispatch refuses to run with no Run bound"
new_project r13
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r13.boot.log" 2>&1
: >"$STATE/calls.log"   # isolate this dispatch's own calls from bootstrap's
"$SCRIPTS/orca-dispatch-role.sh" thrifty --spec "do the thing" \
  >"$tmproot/r13.log" 2>&1
r13_rc=$?
assert R13_nonzero_exit "[[ $r13_rc -ne 0 ]]"
assert R13_no_task_create "[[ \"\$(calls_matching 'orchestration task-create')\" -eq 0 ]]"
assert R13_no_dispatch_call "[[ \"\$(calls_matching 'orchestration dispatch ')\" -eq 0 ]]"
assert R13_no_ledger_row "[[ ! -f \"$PROJ/.orca/orchestration/dispatch-ledger.jsonl\" ]]"
assert R13_says_run_scope "grep -q 'run-create' \"$tmproot/r13.log\""

# --- R14 a message consumed for the wrong task is spooled, not lost --------
# orca-wait-done.sh's task-filtered wait has no per-task selector on the
# underlying `check` call — a non-matching message is unavoidably consumed
# by the poll that received it. Previously that message just evaporated
# (logged to stderr and gone); now it lands in inbox-spool.jsonl and a LATER
# wait for that task recovers it from the spool instead of polling to its
# own timeout having "never" seen it.
echo "R14 wait-done spools a message meant for a different task"
new_project r14
printf 'term_r14\trole-grok-thrifty\n' >>"$STATE/terminals"
cat >"$STATE/check.json" <<'JSON'
{"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_other","subject":"done","payload":{"taskId":"task_other"}}]}}
JSON
"$SCRIPTS/orca-wait-done.sh" --task task_r14_none --timeout-ms 300 \
  >"$tmproot/r14a.log" 2>&1
assert R14_spooled "[[ -f \"$PROJ/.orca/orchestration/inbox-spool.jsonl\" ]]"
assert R14_spool_has_task "grep -q task_other \"$PROJ/.orca/orchestration/inbox-spool.jsonl\""
: >"$STATE/check.json"   # a second wait must not need a fresh `check` result
printf '{"result":{"count":0,"messages":[]}}\n' >"$STATE/check.json"
"$SCRIPTS/orca-wait-done.sh" --task task_other --role thrifty --timeout-ms 300 \
  >"$tmproot/r14b.log" 2>&1
assert R14_recovered "grep -q 'Recovered spooled message' \"$tmproot/r14b.log\""
assert R14_spool_drained "! grep -q task_other \"$PROJ/.orca/orchestration/inbox-spool.jsonl\" 2>/dev/null"

# --- R15 dispatch attaches workers via worker-start, not dispatch --inject --
# references/orca-contract-2026-08-13.md S1-b/S1-c: worker-start accepts our
# pre-created custom-argv terminal and injects the worker's own dispatch
# identity, so the old `orchestration dispatch --to --inject` call is gone.
echo "R15 dispatch uses worker-start, not dispatch --inject"
new_project r15
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r15.boot.log" 2>&1
: >"$STATE/calls.log"
export ORCA_RUN_ID="run_r15"
"$SCRIPTS/orca-dispatch-role.sh" thrifty --spec "do the thing" >"$tmproot/r15.log" 2>&1
r15_rc=$?
unset ORCA_RUN_ID
assert R15_exit0 "[[ $r15_rc -eq 0 ]]"
assert R15_worker_start_called "[[ \"\$(calls_matching 'orchestration worker-start')\" -eq 1 ]]"
assert R15_no_dispatch_inject "[[ \"\$(calls_matching 'orchestration dispatch --task')\" -eq 0 ]]"
r15_task="$(grep -o 'task_id=task_[0-9]*' "$tmproot/r15.log" | head -1 | cut -d= -f2)"
assert R15_ledger_has_dispatch "python3 -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
r=[x for x in rows if x[\"taskId\"]==sys.argv[2]][0]
sys.exit(0 if r.get(\"dispatchId\",\"\").startswith(\"ctx_\") else 1)' \"$PROJ/.orca/orchestration/dispatch-ledger.jsonl\" \"$r15_task\""
# Clean up the background reaper this dispatch started — the fake worker
# never settles on its own, so it would otherwise poll until REAP_TIMEOUT_MS.
r15_pid_file="$PROJ/.orca/orchestration/reapers/$r15_task.pid"
[[ -f "$r15_pid_file" ]] && kill "$(cat "$r15_pid_file")" 2>/dev/null

# --- R16 reaper --dispatch path falls back to close when Orca retains ------
# the tab — the measured DEFAULT for any pre-created custom-argv terminal
# (S1-a). worker-release is still called every time; this asserts it is,
# AND that the fallback close actually fires when release doesn't own it.
echo "R16 reaper (--dispatch path) falls back to close on a retained tab"
new_project r16
printf 'term_r16\trole-grok-thrifty\n' >>"$STATE/terminals"
seed_ledger_row task_r16 term_r16 thrifty
mkdir -p "$STATE/workerstate"
echo succeeded >"$STATE/workerstate/ctx_r16"
"$SCRIPTS/orca-reap-task.sh" --task task_r16 --handle term_r16 --dispatch ctx_r16 \
  --poll-ms 100 --timeout-ms 3000 >"$tmproot/r16.log" 2>&1
r16_rc=$?
assert R16_exit0 "[[ $r16_rc -eq 0 ]]"
assert R16_worker_release_called "[[ \"\$(calls_matching 'orchestration worker-release')\" -eq 1 ]]"
assert R16_fallback_close_called "[[ \"\$(calls_matching 'terminal close')\" -eq 1 ]]"
assert R16_ledger_closed "[[ \"\$(ledger_status task_r16)\" == closed ]]"
assert R16_terminal_gone "[[ \"\$(live_titled term_r16)\" -eq 0 ]]"

# --- R17 reaper --dispatch path uses the native release when Orca reports --
# it — no fallback close call at all.
echo "R17 reaper (--dispatch path) uses native release when Orca owns the tab"
new_project r17
printf 'term_r17\trole-grok-thrifty\n' >>"$STATE/terminals"
seed_ledger_row task_r17 term_r17 thrifty
mkdir -p "$STATE/workerstate" "$STATE/releasestate" "$STATE/releasehandle"
echo succeeded >"$STATE/workerstate/ctx_r17"
echo released >"$STATE/releasestate/ctx_r17"
echo term_r17 >"$STATE/releasehandle/ctx_r17"
"$SCRIPTS/orca-reap-task.sh" --task task_r17 --handle term_r17 --dispatch ctx_r17 \
  --poll-ms 100 --timeout-ms 3000 >"$tmproot/r17.log" 2>&1
r17_rc=$?
assert R17_exit0 "[[ $r17_rc -eq 0 ]]"
assert R17_worker_release_called "[[ \"\$(calls_matching 'orchestration worker-release')\" -eq 1 ]]"
assert R17_no_fallback_close "[[ \"\$(calls_matching 'terminal close')\" -eq 0 ]]"
assert R17_ledger_released "[[ \"\$(ledger_status task_r17)\" == released ]]"
assert R17_terminal_gone "[[ \"\$(live_titled term_r17)\" -eq 0 ]]"

# --- R18 wait-done acks the batch it processes ------------------------------
# Real bug (not theoretical): without --ack, `orchestration check` replays
# the same FIFO batch forever — the root cause behind two known defects in
# templates/SCRIPTS.md ("a leftover worker_done closes the wrong tab", "only
# one waiter at a time"). This just asserts the ack call now happens.
echo "R18 wait-done acks the delivered batch"
new_project r18
cat >"$STATE/check.json" <<'JSON'
{"result":{"count":1,"deliveryId":"delivery_r18","messages":[{"type":"worker_done","from_handle":"term_r18","subject":"done","payload":{"taskId":"task_r18","dispatchId":"ctx_r18"}}]}}
JSON
"$SCRIPTS/orca-wait-done.sh" --timeout-ms 300 >"$tmproot/r18.log" 2>&1
assert R18_acked "grep -q delivery_r18 \"$STATE/acks\" 2>/dev/null"

# --- R19 orca-dispatch-dag.sh wires a full chain but dispatches only step 1 -
# 2-a: the DAG pattern's later steps are created (task-create --deps) so the
# graph exists in Orca up front, but only the first (dependency-free) step
# gets a live worker now — a later step's role may depend on what an earlier
# step actually produced, so it cannot be pre-dispatched, only pre-wired.
echo "R19 orca-dispatch-dag.sh wires explore (thrifty->architect->executor)"
new_project r19
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r19.boot.log" 2>&1
: >"$STATE/calls.log"
export ORCA_RUN_ID="run_r19"
"$SCRIPTS/orca-dispatch-dag.sh" explore "map the auth flow" >"$tmproot/r19.log" 2>&1
r19_rc=$?
unset ORCA_RUN_ID
assert R19_exit0 "[[ $r19_rc -eq 0 ]]"
assert R19_three_task_creates "[[ \"\$(calls_matching 'orchestration task-create')\" -eq 3 ]]"
assert R19_one_worker_start "[[ \"\$(calls_matching 'orchestration worker-start')\" -eq 1 ]]"
assert R19_step1_dispatched "grep -q 'step_1=.*status=dispatched' \"$tmproot/r19.log\""
assert R19_step2_blocked "grep -q 'step_2=.*status=blocked' \"$tmproot/r19.log\""
assert R19_step3_blocked "grep -q 'step_3=.*status=blocked' \"$tmproot/r19.log\""
r19_task1="$(grep -o 'step_1=task_[0-9]*' "$tmproot/r19.log" | head -1 | cut -d= -f2)"
r19_pid_file="$PROJ/.orca/orchestration/reapers/$r19_task1.pid"
[[ -f "$r19_pid_file" ]] && kill "$(cat "$r19_pid_file")" 2>/dev/null

# --- R20 orca-dispatch-existing.sh passes --retry-of through to worker-start
# 2-b (repositioned after the live spike in references/orca-contract-*.md:
# --retry-of is for same-role crash recovery on an EXISTING task, not a
# cross-role failover — the spec text can't be reworded on a retry).
echo "R20 orca-dispatch-existing.sh forwards --retry-of"
new_project r20
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r20.boot.log" 2>&1
: >"$STATE/calls.log"
export ORCA_RUN_ID="run_r20"
"$SCRIPTS/orca-dispatch-existing.sh" task_r20_existing thrifty --retry-of ctx_r20_old >"$tmproot/r20.log" 2>&1
r20_rc=$?
unset ORCA_RUN_ID
assert R20_exit0 "[[ $r20_rc -eq 0 ]]"
assert R20_no_task_create "[[ \"\$(calls_matching 'orchestration task-create')\" -eq 0 ]]"
assert R20_retry_of_forwarded "grep -q -- '--retry-of ctx_r20_old' \"$STATE/calls.log\""
assert R20_ledger_has_task "grep -q task_r20_existing \"$PROJ/.orca/orchestration/dispatch-ledger.jsonl\""
r20_pid_file="$PROJ/.orca/orchestration/reapers/task_r20_existing.pid"
[[ -f "$r20_pid_file" ]] && kill "$(cat "$r20_pid_file")" 2>/dev/null

# --- R21 positional spec + --scope/--done append to the assembled spec -----
echo "R21 positional spec and --scope/--done"
new_project r21
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r21.boot.log" 2>&1
: >"$STATE/calls.log"
export ORCA_RUN_ID="run_r21"
"$SCRIPTS/orca-dispatch-role.sh" thrifty "fix the login bug" \
  --scope src/auth,prisma/schema.prisma --done "pnpm test auth" \
  >"$tmproot/r21.log" 2>&1
r21_rc=$?
unset ORCA_RUN_ID
assert R21_exit0 "[[ $r21_rc -eq 0 ]]"
assert R21_spec_has_body "grep -q 'fix the login bug' \"$STATE/calls.log\""
assert R21_spec_has_scope "grep -q 'Allowed scope: src/auth,prisma/schema.prisma' \"$STATE/calls.log\""
assert R21_spec_has_done "grep -q 'Done: pnpm test auth' \"$STATE/calls.log\""
r21_task="$(grep -o 'task_id=task_[0-9]*' "$tmproot/r21.log" | head -1 | cut -d= -f2)"
r21_pid_file="$PROJ/.orca/orchestration/reapers/$r21_task.pid"
[[ -f "$r21_pid_file" ]] && kill "$(cat "$r21_pid_file")" 2>/dev/null

# --- R22 `or` is a pure routing alias — same effect as the long form -------
echo "R22 or router dispatches, checks status, and refuses unknown subcommands"
new_project r22
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r22.boot.log" 2>&1
: >"$STATE/calls.log"
export ORCA_RUN_ID="run_r22"
"$OR" d thrifty "map the repo" --no-reap >"$tmproot/r22.log" 2>&1
r22_rc=$?
assert R22_d_exit0 "[[ $r22_rc -eq 0 ]]"
assert R22_d_worker_start_called "[[ \"\$(calls_matching 'orchestration worker-start')\" -eq 1 ]]"
"$OR" s >"$tmproot/r22.s.log" 2>&1
assert R22_s_reports_roles "grep -q architect \"$tmproot/r22.s.log\""
unset ORCA_RUN_ID
"$OR" bogus >"$tmproot/r22.bogus.log" 2>&1
r22_bogus_rc=$?
assert R22_unknown_sub_nonzero "[[ $r22_bogus_rc -ne 0 ]]"
assert R22_unknown_sub_message "grep -q 'Unknown subcommand' \"$tmproot/r22.bogus.log\""

# ---------------------------------------------------------------------------
# Recipes (orca-race.sh, orca-review.sh, orca-worktrees.sh, orca-design-fix.sh)
# ---------------------------------------------------------------------------
race_seat_status() {
  # $1=race_id $2=seat → status from race-ledger.jsonl
  python3 - "$PROJ/.orca/orchestration/race-ledger.jsonl" "$1" "$2" <<'PY' 2>/dev/null || echo "__none__"
import json, sys
path, rid, seat = sys.argv[1:4]
out = "__none__"
with open(path) as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("kind") == "seat" and row.get("raceId") == rid and str(row.get("seat")) == seat:
            out = row.get("status") or ""
print(out)
PY
}
race_seat_rows() {
  grep -c '"kind": "seat"' "$PROJ/.orca/orchestration/race-ledger.jsonl" 2>/dev/null | tr -d ' '
}

# --- R23 race start: one worktree + one tab + one dispatch per role ---------
echo "R23 race start creates a worktree, a role tab and a supervised dispatch per seat"
new_project r23
export ORCA_RUN_ID="run_r23"
"$OR" race start "fix the login bug" >"$tmproot/r23.log" 2>&1
r23_rc=$?
R23_ID="$(sed -n 's/^race_id=\([^ ]*\).*/\1/p' "$tmproot/r23.log")"
assert R23_exit0 "[[ $r23_rc -eq 0 ]]"
assert R23_race_id "[[ -n \"$R23_ID\" ]]"
assert R23_three_worktree_creates "[[ \"\$(calls_matching 'worktree create --name fix-the-login-bug-')\" -eq 3 ]]"
assert R23_base_branch_passed "[[ \"\$(calls_matching 'worktree create .*--base-branch ')\" -eq 3 ]]"
assert R23_tabs_in_seat_worktrees "[[ \"\$(calls_matching 'terminal create --worktree path:.*/worktrees/fix-the-login-bug-')\" -eq 3 ]]"
assert R23_worker_start_scoped "[[ \"\$(calls_matching 'worker-start .*--terminal term_.* --worktree path:')\" -eq 3 ]]"
assert R23_seat_rows "[[ \"\$(race_seat_rows)\" -eq 3 ]]"
assert R23_seat_running "[[ \"\$(race_seat_status \"$R23_ID\" 2)\" == running ]]"
assert R23_dispatch_ledger_rows "[[ \"\$(ledger_rows)\" -eq 3 ]]"
assert R23_no_reaper_by_default "[[ ! -d \"$PROJ/.orca/orchestration/reapers\" || -z \"\$(ls -A \"$PROJ/.orca/orchestration/reapers\" 2>/dev/null)\" ]]"
assert R23_checkpoint_comment "grep -q -- '--comment race .* seat 1/3: architect' \"$STATE/wtset.log\""
# handles.json is untouched: race seats never go through ensure_terminal.
assert R23_handles_untouched "! grep -q 'term_' \"$PROJ/.orca/orchestration/handles.json\" 2>/dev/null"
unset ORCA_RUN_ID

# --- R24 race start survives one failed seat, refuses below quorum ----------
echo "R24 race start records a failed seat and enforces the 2-seat quorum"
new_project r24
export ORCA_RUN_ID="run_r24"
# Make ONLY the second worktree create fail: the fake has no per-call failure
# hook, so use a tiny wrapper that fails once and then steps aside.
mkdir -p "$tmproot/r24-bin"
cat >"$tmproot/r24-bin/orca" <<WRAP
#!/usr/bin/env bash
if [[ "\$1 \$2" == "worktree create" && ! -f "$STATE/r24.failed-once" ]]; then
  if [[ -f "$STATE/r24.seen-one" ]]; then
    touch "$STATE/r24.failed-once"
    echo "injected create failure" >&2
    exit 1
  fi
  touch "$STATE/r24.seen-one"
fi
exec "$FAKE_DIR/orca" "\$@"
WRAP
chmod +x "$tmproot/r24-bin/orca"
PATH="$tmproot/r24-bin:$PATH" "$OR" race start "quorum test" --roles architect,executor,thrifty >"$tmproot/r24.log" 2>&1
r24_rc=$?
R24_ID="$(sed -n 's/^race_id=\([^ ]*\).*/\1/p' "$tmproot/r24.log")"
assert R24_exit0_with_quorum "[[ $r24_rc -eq 0 ]]"
assert R24_seat2_start_failed "[[ \"\$(race_seat_status \"$R24_ID\" 2)\" == start_failed ]]"
assert R24_seat3_running "[[ \"\$(race_seat_status \"$R24_ID\" 3)\" == running ]]"
assert R24_started_two "grep -q 'started=2/3' \"$tmproot/r24.log\""
# Every create failing → fewer than 2 seats → exit 2, nothing dispatched.
: >"$STATE/calls.log"
touch "$STATE/fail/worktree-create"
"$OR" race start "no quorum" --roles architect,executor >"$tmproot/r24b.log" 2>&1
r24b_rc=$?
assert R24_below_quorum_exit2 "[[ $r24b_rc -eq 2 ]]"
assert R24_below_quorum_no_worker "[[ \"\$(calls_matching 'worker-start')\" -eq 0 ]]"
rm -f "$STATE/fail/worktree-create"
unset ORCA_RUN_ID

# --- R25 race pick removes the losers, keeps the winner, opens its diff -----
echo "R25 race pick removes losers (stop → release → rm --force) and opens the winner's diff"
new_project r25
export ORCA_RUN_ID="run_r25"
"$OR" race start "pick test" >"$tmproot/r25.log" 2>&1
R25_ID="$(sed -n 's/^race_id=\([^ ]*\).*/\1/p' "$tmproot/r25.log")"
: >"$STATE/calls.log"
"$OR" race pick "$R25_ID" 2 >"$tmproot/r25.pick.log" 2>&1
r25_rc=$?
assert R25_pick_exit0 "[[ $r25_rc -eq 0 ]]"
assert R25_two_rms "[[ \"\$(calls_matching 'worktree rm --worktree path:.*--force')\" -eq 2 ]]"
assert R25_winner_not_removed "! grep -q 'worktree rm --worktree path:.*pick-test-2 ' \"$STATE/calls.log\""
assert R25_stop_and_release_each_loser "[[ \"\$(calls_matching 'worker-stop')\" -eq 2 && \"\$(calls_matching 'worker-release')\" -eq 2 ]]"
assert R25_winner_diff_opened "[[ \"\$(calls_matching 'file open-changed --mode diff --worktree path:.*pick-test-2')\" -eq 1 ]]"
assert R25_winner_in_review "grep -q -- 'pick-test-2 --workspace-status in-review' \"$STATE/wtset.log\""
assert R25_seat1_removed "[[ \"\$(race_seat_status \"$R25_ID\" 1)\" == removed ]]"
assert R25_seat2_winner "[[ \"\$(race_seat_status \"$R25_ID\" 2)\" == winner ]]"
# The losers' tabs went with their worktrees; the winner's tab is still live.
assert R25_loser_tabs_gone "[[ \"\$(live_titled \"$R25_ID-architect\")\" -eq 0 && \"\$(live_titled \"$R25_ID-thrifty\")\" -eq 0 ]]"
assert R25_winner_tab_live "[[ \"\$(live_titled \"$R25_ID-executor\")\" -eq 1 ]]"
# finish releases the winner's tab (retained → fallback close) and keeps the worktree.
"$OR" race finish "$R25_ID" >"$tmproot/r25.done.log" 2>&1
r25d_rc=$?
assert R25_done_exit0 "[[ $r25d_rc -eq 0 ]]"
assert R25_done_tab_closed "[[ \"\$(live_titled \"$R25_ID-executor\")\" -eq 0 ]]"
assert R25_done_no_rm "[[ \"\$(calls_matching 'worktree rm --worktree path:.*pick-test-2')\" -eq 0 ]]"
unset ORCA_RUN_ID

# --- R26 a failed worktree rm is recorded and surfaces in orca-status.sh -----
echo "R26 race pick exits non-zero on a failed rm, marks rm_failed, and status reports it"
new_project r26
export ORCA_RUN_ID="run_r26"
"$OR" race start "rm fail" --roles architect,executor >"$tmproot/r26.log" 2>&1
R26_ID="$(sed -n 's/^race_id=\([^ ]*\).*/\1/p' "$tmproot/r26.log")"
touch "$STATE/fail/worktree-rm"
"$OR" race pick "$R26_ID" 1 >"$tmproot/r26.pick.log" 2>&1
r26_rc=$?
rm -f "$STATE/fail/worktree-rm"
assert R26_pick_nonzero "[[ $r26_rc -ne 0 ]]"
assert R26_seat2_rm_failed "[[ \"\$(race_seat_status \"$R26_ID\" 2)\" == rm_failed ]]"
"$SCRIPTS/orca-status.sh" >"$tmproot/r26.status.log" 2>&1
assert R26_status_reports "grep -q 'rm_failed' \"$tmproot/r26.status.log\""
assert R26_status_problem "grep -q 'FAILED' \"$tmproot/r26.status.log\""
# Retrying the pick removes the seat once rm works again.
"$OR" race pick "$R26_ID" 1 >"$tmproot/r26.pick2.log" 2>&1
r26b_rc=$?
assert R26_retry_exit0 "[[ $r26b_rc -eq 0 ]]"
assert R26_retry_removed "[[ \"\$(race_seat_status \"$R26_ID\" 2)\" == removed ]]"
unset ORCA_RUN_ID

# --- R27 gc is report-only by default, --close removes merged only ----------
echo "R27 gc reports merged worktrees, removes them only with --close and never with --force"
new_project r27
# A real git repo as the "main worktree" so `git branch --merged` is honest.
R27_MAIN="$tmproot/r27-main"
git init -q "$R27_MAIN" && git -C "$R27_MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$R27_MAIN" branch -q fake/merged-one
git -C "$R27_MAIN" checkout -q -b fake/unmerged-one && git -C "$R27_MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip && git -C "$R27_MAIN" checkout -q -
main_branch="$(git -C "$R27_MAIN" rev-parse --abbrev-ref HEAD)"
printf '%s\trefs/heads/%s\n' "$R27_MAIN" "$main_branch" >"$STATE/mainworktree"
orca worktree create --name merged-one --base-branch "$main_branch" --json >/dev/null
orca worktree create --name unmerged-one --base-branch "$main_branch" --json >/dev/null
orca worktree create --name merged-busy --base-branch "$main_branch" --json >/dev/null
git -C "$R27_MAIN" branch -q fake/merged-busy
orca terminal create --worktree "path:$STATE/worktrees/merged-busy" --title busy --command bash --json >/dev/null
: >"$STATE/calls.log"
"$OR" gc >"$tmproot/r27.log" 2>&1
r27_rc=$?
assert R27_report_exit0 "[[ $r27_rc -eq 0 ]]"
assert R27_report_lists_merged "grep -q 'MERGED .*merged-one' \"$tmproot/r27.log\""
assert R27_report_skips_unmerged "! grep -q 'unmerged-one' \"$tmproot/r27.log\""
assert R27_report_skips_busy "grep -q 'SKIP .*merged-busy .*live terminal' \"$tmproot/r27.log\""
assert R27_report_no_rm "[[ \"\$(calls_matching 'worktree rm')\" -eq 0 ]]"
"$OR" gc --close >"$tmproot/r27.close.log" 2>&1
r27c_rc=$?
assert R27_close_exit0 "[[ $r27c_rc -eq 0 ]]"
assert R27_close_removed_merged "[[ \"\$(calls_matching 'worktree rm --worktree path:.*merged-one --json')\" -eq 1 ]]"
assert R27_close_no_force "[[ \"\$(calls_matching 'worktree rm .*--force')\" -eq 0 ]]"
assert R27_close_kept_busy "[[ \"\$(calls_matching 'worktree rm --worktree path:.*merged-busy')\" -eq 0 ]]"
assert R27_close_kept_unmerged "[[ \"\$(calls_matching 'worktree rm --worktree path:.*unmerged-one')\" -eq 0 ]]"
assert R27_main_never_rm "[[ \"\$(calls_matching \"worktree rm --worktree path:$R27_MAIN\")\" -eq 0 ]]"

# --- R28 review opens the diff view (open-changed or file diff) ------------
echo "R28 review opens changed files by default and one file with --path"
new_project r28
"$OR" review >"$tmproot/r28.log" 2>&1
r28_rc=$?
assert R28_default_exit0 "[[ $r28_rc -eq 0 ]]"
assert R28_open_changed_diff "[[ \"\$(calls_matching 'file open-changed --mode diff --worktree active')\" -eq 1 ]]"
assert R28_prints_keys "grep -q 'Send to agent' \"$tmproot/r28.log\""
"$OR" review --path src/app.ts --staged branch:feature >"$tmproot/r28b.log" 2>&1
assert R28_file_diff "[[ \"\$(calls_matching 'file diff src/app.ts --staged --worktree branch:feature')\" -eq 1 ]]"

# --- R29 fix activates the ui tab, then navigates the browser ---------------
echo "R29 fix ensures the ui tab, switches to it, then opens the URL"
new_project r29
# Bootstrap pre-warms only the four primary roles; the ui tab is created
# lazily by ensure_terminal on the first `fix`, and reused on the second.
"$SCRIPTS/orca-bootstrap-roles.sh" --worktree active >"$tmproot/r29.boot.log" 2>&1
: >"$STATE/calls.log"
"$OR" fix http://localhost:3000/settings >"$tmproot/r29.log" 2>&1
r29_rc=$?
assert R29_exit0 "[[ $r29_rc -eq 0 ]]"
assert R29_ui_tab_created "[[ \"\$(calls_matching 'terminal create --worktree active --title role-agy-ui')\" -eq 1 ]]"
assert R29_switch_called "[[ \"\$(calls_matching 'terminal switch --terminal term_')\" -eq 1 ]]"
assert R29_goto_called "[[ \"\$(calls_matching 'goto --url http://localhost:3000/settings --worktree active')\" -eq 1 ]]"
assert R29_switch_before_goto "[[ \"\$(grep -n 'terminal switch' \"$STATE/calls.log\" | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '^goto ' \"$STATE/calls.log\" | head -1 | cut -d: -f1)\" ]]"
: >"$STATE/calls.log"
"$OR" fix http://localhost:3000/settings >"$tmproot/r29b.log" 2>&1
assert R29_second_run_reuses_tab "[[ \"\$(calls_matching 'terminal create')\" -eq 0 && \"\$(calls_matching 'terminal switch')\" -eq 1 ]]"
"$OR" fix --verify >"$tmproot/r29v.log" 2>&1
assert R29_verify_screenshot "[[ \"\$(calls_matching 'screenshot --worktree active')\" -eq 1 ]]"

# --- R30 note/hosts route to single orca calls; race refuses without a Run --
echo "R30 note and hosts are single orca calls; race start refuses with no Run bound"
new_project r30
"$OR" note "reproduced the bug" --workspace-status in-progress >"$tmproot/r30.note.log" 2>&1
r30n_rc=$?
assert R30_note_exit0 "[[ $r30n_rc -eq 0 ]]"
assert R30_note_call "[[ \"\$(calls_matching 'worktree set --worktree active --comment reproduced the bug --workspace-status in-progress --json')\" -eq 1 ]]"
"$OR" hosts >"$tmproot/r30.hosts.log" 2>&1
assert R30_hosts_call "[[ \"\$(calls_matching 'host list --json')\" -eq 1 ]]"
unset ORCA_RUN_ID
: >"$STATE/calls.log"
"$OR" race start "unscoped" >"$tmproot/r30.race.log" 2>&1
r30_rc=$?
assert R30_race_refuses_unscoped "[[ $r30_rc -ne 0 ]]"
assert R30_race_no_worktree "[[ \"\$(calls_matching 'worktree create')\" -eq 0 ]]"
assert R30_race_hint "grep -q 'no Run bound' \"$tmproot/r30.race.log\""

echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
