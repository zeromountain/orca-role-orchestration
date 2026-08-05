#!/usr/bin/env bash
# Runtime script tests (R1–R6). Exit 0 only if all assert.
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

# new_project <name> → echoes the scripts dir; sets STATE/PROJ globals
PROJ=""
STATE=""
SCRIPTS=""
new_project() {
  PROJ="$tmproot/$1"
  mkdir -p "$PROJ"
  "$INSTALL" --project-root "$PROJ" --project-name "$1" >"$tmproot/$1.install.log" 2>&1
  SCRIPTS="$PROJ/.orca/orchestration/scripts"
  STATE="$tmproot/$1.state"
  # Same layout the fake creates on first call — tests write here beforehand.
  mkdir -p "$STATE/sends" "$STATE/preview" "$STATE/status" "$STATE/fail"
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
assert R1_title_architect "grep -q role-opus-architect \"$STATE/calls.log\""
assert R1_title_executor "grep -q role-sol-executor \"$STATE/calls.log\""
assert R1_title_thrifty "grep -q role-grok-thrifty \"$STATE/calls.log\""
assert R1_title_fallback "grep -q role-agy-fallback \"$STATE/calls.log\""
assert R1_handles_parse "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \"$H\""
assert R1_architect_model "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"roles\"][\"architect\"][\"model\"]==\"claude-opus-4-8\" else 1)' \"$H\""
assert R1_four_live "[[ \"\$(live_titled role-)\" -eq 4 ]]"
# A bootstrapped worker and a dispatch-recreated one must be told the same model
# string. They were not: bootstrap seeded the display name ("Claude Opus 4.8"),
# ensure_terminal seeded the model ID. Both go through ensure_terminal now.
arch_handle="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["roles"]["architect"]["handle"])' "$H" 2>/dev/null || echo none)"
assert R1_seed_model_id "grep -q 'claude-opus-4-8' \"$STATE/sends/$arch_handle\""

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
echo "R4 close when liveness probe is unreadable  [regression: bug B]"
new_project r4
printf 'term_97\trole-sol-executor\n' >>"$STATE/terminals"
seed_ledger_row task_r4 term_97 executor
echo completed >"$STATE/status/task_r4"
: >"$STATE/fail/terminal-list"   # daemon hiccup: `terminal list` exits 1
"$SCRIPTS/orca-reap-task.sh" --task task_r4 --handle term_97 --poll-ms 100 --timeout-ms 3000 \
  >"$tmproot/r4.log" 2>&1
r4_rc=$?
assert R4_exit0 "[[ $r4_rc -eq 0 ]]"
assert R4_closed_anyway "[[ \"\$(calls_matching 'terminal close')\" -ge 1 ]]"
assert R4_terminal_gone "[[ \"\$(live_titled term_97)\" -eq 0 ]]"
assert R4_ledger_closed "[[ \"\$(ledger_status task_r4)\" == closed ]]"

# --- R4b close genuinely fails → escalate (RED until Tier 1.1/1.3) ---
echo "R4b close genuinely fails  [regression: bug A]"
new_project r4b
printf 'term_96\trole-sol-executor\n' >>"$STATE/terminals"
seed_ledger_row task_r4b term_96 executor
echo completed >"$STATE/status/task_r4b"
: >"$STATE/fail/terminal-close"  # every close attempt exits 1
"$SCRIPTS/orca-reap-task.sh" --task task_r4b --handle term_96 --poll-ms 100 --timeout-ms 3000 \
  >"$tmproot/r4b.log" 2>&1
r4b_rc=$?
assert R4b_nonzero_exit "[[ $r4b_rc -ne 0 ]]"
assert R4b_not_marked_closed "[[ \"\$(ledger_status task_r4b)\" != closed ]]"
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
assert R8_default_role_intact "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"roles\"][\"architect\"][\"model\"]==\"claude-opus-4-8\" else 1)' \"$H8\""
assert R8_no_grok_launch "! grep -q 'grok --model grok-4.5' \"$STATE/calls.log\""
# The installer must never clobber this user-owned file.
"$INSTALL" --project-root "$PROJ" --project-name r8 >"$tmproot/r8.reinstall.log" 2>&1
assert R8_survives_upgrade "grep -q claude-sonnet-5 \"$PROJ/.orca/orchestration/roles.local.json\""
"$INSTALL" --project-root "$PROJ" --project-name r8 --reset >"$tmproot/r8.reset.log" 2>&1
assert R8_survives_reset "grep -q claude-sonnet-5 \"$PROJ/.orca/orchestration/roles.local.json\""

echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
