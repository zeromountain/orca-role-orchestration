#!/usr/bin/env bash
# Coordinator-side view of the "Jump between 10 worktrees" recipe: the parts
# of it that have a CLI. The Jump Palette (Cmd-J), the Restart chip and the
# notification bell are UI-only; what a coordinator can do from here is
# (a) see every worktree with its agents and who is waiting for input, and
# (b) delete merged worktrees aggressively — the recipe's own tip.
#
#   orca-worktrees.sh ps                       table of worktrees / agents / race seats
#   orca-worktrees.sh gc [--base <ref>] [--close]
#
# gc has the same polarity as orca-sweep-orphans.sh: report-only unless
# --close. It never passes --force to `worktree rm`, so Orca's own "cannot
# prove merged" branch guard stays in force, and it skips the main worktree,
# the worktree the shell is in, and any worktree with live terminals.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
RACE_LEDGER="$ORCH/race-ledger.jsonl"

usage() {
  cat <<'EOF'
Usage:
  orca-worktrees.sh ps
  orca-worktrees.sh gc [--base <ref>] [--close]

ps   every Orca worktree: branch, live terminals, agent states, comment, and
     any race seat living there (worker state, needs-input).
gc   list worktrees whose branch is already merged into --base (default: the
     main worktree's branch). --close removes them (`orca worktree rm`, no
     --force). Main worktree, the current directory's worktree, and worktrees
     with live terminals are never removed.
EOF
}

seat_index() {
  # → TSV "path<TAB>raceId<TAB>seat<TAB>role<TAB>status<TAB>dispatchId" for
  # every race seat that still has a worktree path.
  [[ -f "$RACE_LEDGER" ]] || return 0
  python3 - "$RACE_LEDGER" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("kind") != "seat" or not row.get("path"):
            continue
        if row.get("status") in ("removed",):
            continue
        print("\t".join(str(row.get(k) or "-") for k in ("path", "raceId", "seat", "role", "status", "dispatchId")))
PY
}

worker_needs_input() {
  # $1=dispatch → "needs-input" | "live" | "exited" | "?" from worker-show's
  # observation block (agentWait non-null is the recipe's yellow dot).
  orca orchestration worker-show --dispatch "$1" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("?"); sys.exit(0)
r = d.get("result") or {}
obs = r.get("observation") or {}
if obs.get("agentWait"):
    print("needs-input")
else:
    print(obs.get("status") or (r.get("worker") or {}).get("state") or "?")
' 2>/dev/null || echo "?"
}

cmd_ps() {
  local rows seats path branch main live agents comment status
  rows="$(orca worktree ps --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for w in (d.get("result") or {}).get("worktrees") or []:
    agents = ",".join("%s:%s" % (a.get("agentType") or "?", a.get("state") or "?") for a in (w.get("agents") or [])) or "-"
    branch = (w.get("branch") or "-").replace("refs/heads/", "")
    print("\t".join(str(x) for x in (
        w.get("path") or "-", branch, "main" if w.get("isMainWorktree") else "-",
        w.get("liveTerminalCount") or 0, agents, w.get("comment") or "-", w.get("workspaceStatus") or "-")))
')"
  seats="$(seat_index)"
  printf '%-6s %-28s %-5s %-24s %s\n' term branch main agents path
  while IFS=$'\t' read -r path branch main live agents comment status; do
    [[ -n "$path" ]] || continue
    printf '%-6s %-28s %-5s %-24s %s\n' "$live" "${branch:0:28}" "$main" "${agents:0:24}" "$path"
    [[ "$comment" != "-" ]] && printf '       note: %s  [%s]\n' "$comment" "$status"
    if [[ -n "$seats" ]]; then
      while IFS=$'\t' read -r spath rid seat role sstatus dispatch; do
        [[ "$spath" == "$path" ]] || continue
        printf '       race %s seat %s (%s): %s' "$rid" "$seat" "$role" "$sstatus"
        [[ "$dispatch" != "-" ]] && printf ' — worker %s' "$(worker_needs_input "$dispatch")"
        printf '\n'
      done <<<"$seats"
    fi
  done <<<"$rows"
  echo ""
  echo "UI only: Cmd-J jump palette (Shift-Enter opens in a split), Restart chip (= orca terminal create --worktree <sel> --command <launch>), notification bell."
}

cmd_gc() {
  local base="" close=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) base="${2:?}"; shift 2 ;;
      --close) close=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown: $1" >&2; usage; exit 1 ;;
    esac
  done
  local listing main_path main_branch merged cwd_wt
  listing="$(orca worktree list --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
for w in (d.get("result") or {}).get("worktrees") or []:
    print("\t".join(str(x) for x in (w.get("path") or "-", w.get("branch") or "-", "1" if w.get("isMainWorktree") else "0")))
')"
  main_path="$(printf '%s\n' "$listing" | awk -F'\t' '$3=="1"{print $1; exit}')"
  main_branch="$(printf '%s\n' "$listing" | awk -F'\t' '$3=="1"{print $2; exit}')"
  if [[ -z "$main_path" ]]; then echo "gc: no main worktree in orca worktree list" >&2; exit 1; fi
  [[ -z "$base" ]] && base="${main_branch#refs/heads/}"
  [[ -z "$base" || "$base" == "-" ]] && base="main"
  merged="$(git -C "$main_path" branch --merged "$base" --format='%(refname)' 2>/dev/null || true)"
  if [[ -z "$merged" ]]; then
    echo "gc: git -C $main_path branch --merged $base returned nothing (not a git checkout, or unknown base)" >&2
    exit 1
  fi
  cwd_wt="$(orca worktree current --json 2>/dev/null | python3 -c '
import json, sys
try:
    print(((json.load(sys.stdin).get("result") or {}).get("worktree") or {}).get("path") or "")
except Exception:
    print("")
' 2>/dev/null || true)"

  local mode="report-only"
  [[ "$close" -eq 1 ]] && mode="close mode"
  echo "gc: base=$base main=$main_path ($mode)"
  local path branch is_main live n_cand=0 n_removed=0 n_failed=0
  while IFS=$'\t' read -r path branch is_main; do
    [[ -n "$path" && "$is_main" != "1" ]] || continue
    printf '%s\n' "$merged" | grep -qx -- "$branch" || continue
    n_cand=$((n_cand + 1))
    if [[ -n "$cwd_wt" && "$path" == "$cwd_wt" ]]; then
      echo "  SKIP    $path (${branch#refs/heads/}) — current directory's worktree"
      continue
    fi
    live="$(orca terminal list --worktree "path:$path" --json 2>/dev/null | python3 -c '
import json, sys
try:
    print(len((json.load(sys.stdin).get("result") or {}).get("terminals") or []))
except Exception:
    print("?")
' 2>/dev/null || echo "?")"
    if [[ "$live" != "0" ]]; then
      echo "  SKIP    $path (${branch#refs/heads/}) — $live live terminal(s); close them or use 'or race abort' first"
      continue
    fi
    if [[ "$close" -eq 0 ]]; then
      echo "  MERGED  $path (${branch#refs/heads/})"
      continue
    fi
    if orca worktree rm --worktree "path:$path" --json >/dev/null 2>&1; then
      echo "  REMOVED $path (${branch#refs/heads/})"
      n_removed=$((n_removed + 1))
    else
      echo "  FAILED  $path (${branch#refs/heads/}) — orca worktree rm exited non-zero" >&2
      n_failed=$((n_failed + 1))
    fi
  done <<<"$listing"
  if [[ "$close" -eq 0 ]]; then
    echo "gc: $n_cand merged worktree(s). Re-run with --close to remove them."
  else
    echo "gc: removed $n_removed, failed $n_failed of $n_cand merged worktree(s)."
    [[ "$n_failed" -eq 0 ]] || exit 1
  fi
}

[[ $# -ge 1 ]] || { usage; exit 1; }
SUB="$1"; shift
case "$SUB" in
  ps) cmd_ps "$@" ;;
  gc) cmd_gc "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown: $SUB" >&2; usage; exit 1 ;;
esac
