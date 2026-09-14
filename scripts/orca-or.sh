#!/usr/bin/env bash
# Thin subcommand router, installed as `.orca/orchestration/or`. Routing
# only — every subcommand `exec`s an existing script or a single `orca`
# call. Never duplicate logic here; if a subcommand needs a decision beyond
# picking which script to run, that decision belongs in the script it
# routes to, not in this file. `up` is the one exception (see below) because
# there is no single existing script that already does "status, then Run
# check, then bootstrap" — everything else here is a pure alias.
#
# Every long-form script keeps working directly; this is a short alias on
# top, not a replacement.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Unlike every OTHER script here, `or` installs one level UP from
# scripts/ (.orca/orchestration/or, not .orca/orchestration/scripts/or) —
# a short top-level alias. Its own $HERE is therefore the orchestration
# root when installed, but scripts/ itself when run straight from the
# skill source tree (dev testing). Resolve both without guessing which.
if [[ -f "$HERE/orca-roles-lib.sh" ]]; then
  SCRIPTS_DIR="$HERE"
else
  SCRIPTS_DIR="$HERE/scripts"
fi
# shellcheck source=orca-roles-lib.sh
source "$SCRIPTS_DIR/orca-roles-lib.sh"

usage() {
  cat <<'EOF'
Usage: or <subcommand> [args...]

  up                              status -> Run check -> bootstrap, one call
  d     <role> "<spec>" [flags]   orca-dispatch-role.sh (spec may be positional)
  dag   <pattern> "<goal>"        orca-dispatch-dag.sh
  x     <task_id> <role> [flags]  orca-dispatch-existing.sh (--retry-of for same-role recovery)
  w     [flags]                   orca-wait-done.sh
  s     [flags]                   orca-status.sh
  f     [flags]                   orca-fallback-on-limit.sh
  sweep [flags]                   orca-sweep-orphans.sh
  debate [flags]                  orca-debate.sh
  close [flags]                   orca-close-role.sh (manual emergency)
  read  <dispatch_id> [flags]     orca orchestration worker-read --dispatch <id>
  reply <msg_id> <body> [flags]   orca orchestration reply --id <id> --body <body>

Recipes (see PLAYBOOK.md "Recipes"):
  race  start|status|pick|finish|abort|list   orca-race.sh — N roles, one worktree each
  review [sel] [flags]            orca-review.sh — open the diff viewer + review keys
  ps                              orca-worktrees.sh ps — worktrees, agents, who needs input
  gc    [--base ref] [--close]    orca-worktrees.sh gc — merged worktrees (report-only by default)
  fix   <url> [flags]             orca-design-fix.sh — Design Mode bug-fix loop
  note  "<text>" [flags]          orca worktree set --worktree active --comment <text> [flags]
  hosts                           orca host list --json

Every subcommand accepts every flag its target script accepts — `or` does not
reinterpret or validate them, it only decides which script/command to run.
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi
SUB="$1"; shift

case "$SUB" in
  up)
    # The one non-alias subcommand: no single existing script already chains
    # "report health, confirm a Run is bound, then bootstrap" — status and
    # bootstrap are independently useful and stay separate scripts, this
    # just sequences them for the common first-run/every-run case.
    "$SCRIPTS_DIR/orca-status.sh" || true
    RUN_ID="$(resolve_run_id)"
    if [[ -z "$RUN_ID" ]]; then
      echo >&2
      run_scope_hint >&2
      exit 1
    fi
    exec "$SCRIPTS_DIR/orca-bootstrap-roles.sh" "$@"
    ;;
  d)
    exec "$SCRIPTS_DIR/orca-dispatch-role.sh" "$@"
    ;;
  dag)
    exec "$SCRIPTS_DIR/orca-dispatch-dag.sh" "$@"
    ;;
  x)
    exec "$SCRIPTS_DIR/orca-dispatch-existing.sh" "$@"
    ;;
  w)
    exec "$SCRIPTS_DIR/orca-wait-done.sh" "$@"
    ;;
  s)
    exec "$SCRIPTS_DIR/orca-status.sh" "$@"
    ;;
  f)
    exec "$SCRIPTS_DIR/orca-fallback-on-limit.sh" "$@"
    ;;
  sweep)
    exec "$SCRIPTS_DIR/orca-sweep-orphans.sh" "$@"
    ;;
  debate)
    exec "$SCRIPTS_DIR/orca-debate.sh" "$@"
    ;;
  close)
    exec "$SCRIPTS_DIR/orca-close-role.sh" "$@"
    ;;
  read)
    if [[ $# -lt 1 ]]; then echo "Usage: or read <dispatch_id> [flags]" >&2; exit 1; fi
    DISPATCH_ID="$1"; shift
    exec orca orchestration worker-read --dispatch "$DISPATCH_ID" "$@"
    ;;
  reply)
    if [[ $# -lt 2 ]]; then echo "Usage: or reply <msg_id> <body> [flags]" >&2; exit 1; fi
    MSG_ID="$1"; BODY="$2"; shift 2
    exec orca orchestration reply --id "$MSG_ID" --body "$BODY" "$@"
    ;;
  # --- recipes (scripts/orca-race.sh & co.; see PLAYBOOK.md "Recipes") ---
  race)
    exec "$SCRIPTS_DIR/orca-race.sh" "$@"
    ;;
  review)
    exec "$SCRIPTS_DIR/orca-review.sh" "$@"
    ;;
  ps)
    exec "$SCRIPTS_DIR/orca-worktrees.sh" ps "$@"
    ;;
  gc)
    exec "$SCRIPTS_DIR/orca-worktrees.sh" gc "$@"
    ;;
  fix)
    exec "$SCRIPTS_DIR/orca-design-fix.sh" "$@"
    ;;
  note)
    # One `orca` call (worktree checkpoint): comment on the active worktree.
    # Extra flags pass straight through (e.g. --workspace-status in-review).
    if [[ $# -lt 1 ]]; then echo "Usage: or note \"<text>\" [--workspace-status <id>]" >&2; exit 1; fi
    NOTE="$1"; shift
    exec orca worktree set --worktree active --comment "$NOTE" "$@" --json
    ;;
  hosts)
    exec orca host list --json "$@"
    ;;
  -h|--help)
    usage; exit 0 ;;
  *)
    echo "Unknown subcommand: $SUB" >&2
    usage
    exit 1
    ;;
esac
