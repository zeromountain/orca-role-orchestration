#!/usr/bin/env bash
# What is this scaffold's actual state right now?
#
#   1 preflight  — orca reachable, role CLIs on PATH
#   2 roles      — handles.json entries, live / dead / unknown per handle
#   3 in-flight  — ledger rows that never reached `closed` (leaks land here)
#   4 reapers    — background watchers, alive or stale
#
# Run this first whenever a dispatch behaves strangely. Exit 1 if anything in
# sections 1-3 needs attention, so it doubles as a smoke check.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
HANDLES_FILE="$ORCH/handles.json"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"
REAPER_DIR="$ORCH/reapers"
MANIFEST="$ORCH/install-manifest.json"
ROLES="architect executor thrifty fallback"
PROBLEMS=0

usage() {
  cat <<'EOF'
Usage: orca-status.sh [--quiet]

  (default)  full report
  --quiet    print only problems
Exit 0 = healthy, 1 = something needs attention.
EOF
}

QUIET=0
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --quiet) QUIET=1 ;;
  "") ;;
  *) echo "Unknown: $1" >&2; usage; exit 1 ;;
esac

say() { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*"; }
problem() { printf '%s\n' "$*" >&2; PROBLEMS=$((PROBLEMS + 1)); }

version_info="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print((d.get("skill_version") or "unknown") + "\t" + (d.get("installed_at") or "unknown"))
except Exception:
    print("unknown\tunknown")
' "$MANIFEST" 2>/dev/null || echo "unknown	unknown")"
version="${version_info%%$'\t'*}"
installed_at="${version_info#*$'\t'}"
say "orca-role-orchestration scaffold ($version)"
say "  root: $ORCH"
if [[ "$version" == "unknown" ]]; then
  say "  install: legacy or missing install-manifest.json — re-run scripts/install-to-project.sh"
else
  say "  installed: $installed_at"
fi
say ""

# --- 1 preflight ------------------------------------------------------------
say "[1] preflight"
if command -v orca >/dev/null 2>&1; then
  if orca_reachable; then
    say "  orca            reachable"
  else
    problem "  orca            NOT REACHABLE — open Orca, or check: orca status --json"
  fi
else
  problem "  orca            not on PATH"
fi
for role in $ROLES; do
  cli="$(role_cli "$role")"
  if command -v "$cli" >/dev/null 2>&1; then
    say "  $role$(printf '%*s' $((12 - ${#role})) '')$cli"
  else
    problem "  $role$(printf '%*s' $((12 - ${#role})) '')$cli NOT on PATH (bootstrap --roles can skip this role)"
  fi
done
say ""

# --- 2 roles ----------------------------------------------------------------
say "[2] roles"
if [[ ! -f "$HANDLES_FILE" ]]; then
  say "  no handles.json — run orca-bootstrap-roles.sh"
else
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$HANDLES_FILE" 2>/dev/null; then
    problem "  handles.json is not readable JSON — re-run orca-bootstrap-roles.sh"
  else
    for role in $ROLES; do
      handle="$(handles_get "$HANDLES_FILE" "$role")"
      if [[ -z "${handle// }" ]]; then
        say "  $role$(printf '%*s' $((12 - ${#role})) '')—"
        continue
      fi
      terminal_is_live "$handle"
      case "$?" in
        0) say "  $role$(printf '%*s' $((12 - ${#role})) '')$handle  live" ;;
        1) say "  $role$(printf '%*s' $((12 - ${#role})) '')$handle  closed (next dispatch recreates)" ;;
        *) problem "  $role$(printf '%*s' $((12 - ${#role})) '')$handle  UNKNOWN — Orca unreachable" ;;
      esac
    done
  fi
fi
say ""

# --- 3 in-flight / leaked ---------------------------------------------------
say "[3] dispatches not closed"
if [[ ! -f "$LEDGER_FILE" ]]; then
  say "  (no ledger yet)"
else
  OPEN_ROWS="$(python3 - "$LEDGER_FILE" <<'PY'
import json, sys

rows = []
with open(sys.argv[1]) as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("status") != "closed":
            rows.append(row)
for row in rows:
    print("  {status:<13} {role:<10} {task}  {handle}".format(
        status=row.get("status") or "?",
        role=row.get("role") or "?",
        task=row.get("taskId") or "?",
        handle=row.get("handle") or "?",
    ))
print("__COUNT__%d" % len(rows))
PY
)"
  count="$(printf '%s' "$OPEN_ROWS" | sed -n 's/^__COUNT__//p')"
  printf '%s\n' "$OPEN_ROWS" | grep -v '^__COUNT__' | grep -v '^$' || true
  if [[ "${count:-0}" -gt 0 ]]; then
    # reap_failed/close_failed: the reaper gave up with the tab possibly
    # still open. stalled/closed_stalled: the idle probe found a worker that
    # stopped making progress (see orca-reap-task.sh) — the tab itself may
    # already be closed, but the underlying task never actually reported
    # done and is worth a human look either way.
    if printf '%s' "$OPEN_ROWS" | grep -q 'reap_failed\|close_failed\|stalled'; then
      problem "  ${count} open row(s), including FAILED or STALLED dispatches — worker tabs may still be burning sessions, or finished without reporting."
      problem "    close manually: orca-close-role.sh <role|term_*>"
    else
      say "  ${count} row(s) still in flight"
    fi
  else
    say "  (all closed)"
  fi
fi
say ""

# --- 4 reapers --------------------------------------------------------------
say "[4] reapers"
if [[ ! -d "$REAPER_DIR" ]]; then
  say "  (none)"
else
  found=0
  for pidfile in "$REAPER_DIR"/*.pid; do
    [[ -e "$pidfile" ]] || continue
    found=$((found + 1))
    pid="$(cat "$pidfile" 2>/dev/null || echo "")"
    task="$(basename "$pidfile" .pid)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      say "  running  pid=$pid  $task"
    else
      say "  stale    pid=${pid:-?}  $task"
    fi
  done
  [[ "$found" -eq 0 ]] && say "  (none)"
fi

if [[ "$PROBLEMS" -gt 0 ]]; then
  echo "" >&2
  echo "$PROBLEMS problem(s) found." >&2
  exit 1
fi
say ""
say "OK"
exit 0
