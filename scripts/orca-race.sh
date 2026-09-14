#!/usr/bin/env bash
# Race N role workers on the same goal, one fresh worktree each — the Orca
# "Race three agents on the same task" recipe, driven from the coordinator.
#
#   orca-race.sh start "<goal>" [--roles architect,executor,thrifty] [--name <slug>]
#                              [--base-branch <ref>] [--repo <selector>]
#                              [--project <id> --host <host-id>] [--reap]
#   orca-race.sh status <race_id>
#   orca-race.sh pick   <race_id> <seat>       keep one seat, remove the others
#   orca-race.sh finish <race_id>              release the winner's tab (worktree stays)
#   orca-race.sh abort  <race_id> [--include-winner]
#   orca-race.sh list
#
# Every seat is a real supervised dispatch (task-create + worker-start on a
# pre-created role tab), so `or s` / `or w` see it like any other dispatch.
# What differs from orca-dispatch-role.sh:
#   - each seat gets its OWN worktree (`orca worktree create --base-branch`),
#     so N seats of the same role never collide on handles.json — seats live in
#     race-ledger.jsonl instead, and ensure_terminal/handles_set are never used;
#   - seat tabs are RETAINED after they settle (the diff viewer's "Send to
#     agent" needs a live agent in that worktree); `pick`/`finish`/`abort` are
#     the close, `--reap` opts back into the auto-reaper;
#   - losers are removed with `worktree rm --force`, which (measured, see
#     references/orca-recipes-spike-2026-09-14.md S4) closes their tabs and
#     deletes their branch. Only ledger-known, non-main worktrees are ever
#     removed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
RACE_LEDGER="$ORCH/race-ledger.jsonl"
LEDGER_FILE="$ORCH/dispatch-ledger.jsonl"
REAP_TIMEOUT_MS=3600000
# Read by seed() in orca-roles-lib.sh.
# shellcheck disable=SC2034
PROJECT_NAME="$(basename "$ROOT")"

usage() {
  cat <<'EOF'
Usage:
  orca-race.sh start "<goal>" [--roles r1,r2,r3] [--name slug] [--base-branch ref]
                              [--repo sel | --project id --host host-id] [--reap]
  orca-race.sh status <race_id>
  orca-race.sh pick   <race_id> <seat>
  orca-race.sh finish <race_id>
  orca-race.sh abort  <race_id> [--include-winner]
  orca-race.sh list

start   one worktree + one role tab + one supervised dispatch per role
        (default roles: architect,executor,thrifty — three providers).
        Exit 0 when >= 2 seats started, 2 when fewer (quorum), 1 on usage.
status  worker state + working-tree diffstat per seat.
pick    keep <seat> (opens its diff, marks in-review), remove every other
        seat's worktree. Winner's tab stays open for "Send to agent".
finish  release the winner's tab; its worktree is kept for commit/push.
abort   remove every running/failed seat; the winner only with --include-winner.
  --reap     auto-release each seat's tab when it settles (default: retain)
  --timeout-ms N   reaper lifetime with --reap (default 3600000)
  --host     pass-through for remote seats (needs --project); untested here.
EOF
}

# --- ledger helpers ---------------------------------------------------------

race_journal() {
  # $1=kind $2=race_id $3=seat $4=raw json (may be non-JSON) — locked append
  # of a raw receipt, BEFORE it is parsed, same reason create_role journals
  # terminal creates: a create that succeeded but failed to parse must still
  # be findable for cleanup.
  python3 - "$RACE_LEDGER" "$1" "$2" "$3" "$4" <<'PY'
import datetime, fcntl, json, os, sys
path, kind, race_id, seat, raw = sys.argv[1:6]
try:
    parsed = json.loads(raw) if raw else None
except Exception:
    parsed = None
row = {"kind": kind, "raceId": race_id, "seat": int(seat) if seat.isdigit() else seat,
       "raw": parsed if parsed is not None else raw,
       "at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")
PY
}

race_seat_append() {
  # k=v pairs → one kind=seat row. Values are strings; empty → null.
  ledger_append "$RACE_LEDGER" "kind=seat" "$@"
}

race_seat_mark() {
  # $1=race_id $2=seat $3=status [k=v…] — locked read-modify-write of the
  # seat row (temp + os.replace, flock on the sidecar), the same shape as
  # orca-reap-task.sh's mark_ledger. Adds "<status>At".
  local race_id="$1" seat="$2" status="$3"
  shift 3
  [[ -f "$RACE_LEDGER" ]] || return 0
  python3 - "$RACE_LEDGER" "$race_id" "$seat" "$status" "$@" <<'PY'
import datetime, fcntl, json, os, sys
path, race_id, seat, status = sys.argv[1:5]
extra = {}
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    extra[k] = v
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except Exception:
                rows.append(line)
                continue
            if row.get("kind") == "seat" and row.get("raceId") == race_id and str(row.get("seat")) == seat:
                row["status"] = status
                row[status + "At"] = now
                row.update(extra)
            rows.append(json.dumps(row))
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    os.replace(tmp, path)
PY
}

dispatch_ledger_mark() {
  # $1=task_id $2=status — mirror the seat's outcome into dispatch-ledger.jsonl
  # so `or s` stops listing a seat whose tab the worktree rm already closed.
  local task_id="$1" status="$2"
  [[ -f "$LEDGER_FILE" ]] || return 0
  python3 - "$LEDGER_FILE" "$task_id" "$status" <<'PY' 2>/dev/null || true
import datetime, fcntl, json, os, sys
path, tid, status = sys.argv[1:4]
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except Exception:
                rows.append(line)
                continue
            if row.get("taskId") == tid:
                row["status"] = status
                row["closedAt"] = now
            rows.append(json.dumps(row))
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    os.replace(tmp, path)
PY
}

race_seats() {
  # $1=race_id → TSV: seat role status path handle taskId dispatchId baseRef
  # (every field non-empty: "-" placeholder, see orca-sweep-orphans.sh on
  # why an empty TSV field shifts everything after it under `read`).
  [[ -f "$RACE_LEDGER" ]] || return 0
  python3 - "$RACE_LEDGER" "$1" <<'PY'
import json, sys
path, race_id = sys.argv[1:3]
def f(v):
    v = "" if v is None else str(v)
    return v if v else "-"
with open(path) as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("kind") != "seat" or row.get("raceId") != race_id:
            continue
        print("\t".join(f(row.get(k)) for k in
              ("seat", "role", "status", "path", "handle", "taskId", "dispatchId", "baseRef")))
PY
}

# --- worktree helpers -------------------------------------------------------

worktree_create() {
  # $1=name $2=base_ref, then extra args (--repo/--project/--host). Prints
  # "id<TAB>path<TAB>branch" or nothing (return 1). Raw receipt is journaled
  # first (kind=worktree_create) so a parse failure never hides a checkout.
  local name="$1" base="$2" race_id="$3" seat="$4" raw parsed
  shift 4
  raw="$(orca worktree create --name "$name" --base-branch "$base" "$@" --json)" || true
  race_journal worktree_create "$race_id" "$seat" "$raw"
  parsed="$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
r = d.get("result") or {}
w = r.get("worktree") or {}
if d.get("ok") is False or not w.get("path"):
    sys.exit(0)
print("%s\t%s\t%s" % (w.get("id") or "", w.get("path"), w.get("branch") or ""))
' 2>/dev/null || true)"
  if [[ -z "$parsed" ]]; then
    # Second chance: the create may have succeeded with an unparsable receipt.
    parsed="$(orca worktree list --json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in (d.get("result") or {}).get("worktrees") or []:
    p = w.get("path") or ""
    if p.rstrip("/").endswith("/" + name) or w.get("displayName") == name:
        print("%s\t%s\t%s" % (w.get("id") or "", p, w.get("branch") or ""))
        break
' "$name" 2>/dev/null || true)"
  fi
  [[ -n "$parsed" ]] || return 1
  printf '%s\n' "$parsed"
}

worktree_is_main() {
  # $1=path → 0 if Orca reports this path as a main worktree (never remove).
  orca worktree show --worktree "path:$1" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
w = ((d.get("result") or {}).get("worktree")) or {}
sys.exit(0 if w.get("isMainWorktree") else 1)
'
}

worktree_gone() {
  # $1=path → 0 once `worktree show` no longer resolves it.
  local out
  out="$(orca worktree show --worktree "path:$1" --json 2>/dev/null)" || return 0
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
sys.exit(1 if d.get("ok", True) and (d.get("result") or {}).get("worktree") else 0)
'
}

seat_remove() {
  # $1=race_id $2=seat $3=path $4=dispatch $5=task → 0 removed, 1 otherwise.
  # Order measured live (spike S4): stop (settles an active worker — release
  # refuses one), release (retained is fine, it is our external tab), then
  # rm --force (closes the tabs, deletes checkout + branch), then verify.
  local race_id="$1" seat="$2" path="$3" dispatch="$4" task="$5"
  if [[ "$path" == "-" || "$path" == "$ROOT" ]]; then
    echo "race: seat $seat has no removable path ($path) — skipping" >&2
    race_seat_mark "$race_id" "$seat" rm_failed "reason=no-path"
    return 1
  fi
  if worktree_is_main "$path"; then
    echo "race: seat $seat path is a MAIN worktree — refusing to remove $path" >&2
    race_seat_mark "$race_id" "$seat" rm_failed "reason=main-worktree"
    return 1
  fi
  if [[ "$dispatch" != "-" ]]; then
    orca orchestration worker-stop --dispatch "$dispatch" --json >/dev/null 2>&1 || true
    orca orchestration worker-release --dispatch "$dispatch" --json >/dev/null 2>&1 || true
  fi
  if ! orca worktree rm --worktree "path:$path" --force --json >/dev/null 2>&1; then
    echo "race: worktree rm failed for seat $seat ($path)" >&2
    race_seat_mark "$race_id" "$seat" rm_failed "reason=rm-exit-nonzero"
    return 1
  fi
  if ! worktree_gone "$path"; then
    echo "race: worktree rm returned but $path still resolves — not marking removed" >&2
    race_seat_mark "$race_id" "$seat" rm_failed "reason=still-present"
    return 1
  fi
  race_seat_mark "$race_id" "$seat" removed
  [[ "$task" != "-" ]] && dispatch_ledger_mark "$task" closed
  echo "race: seat $seat removed ($path)"
  return 0
}

# --- start ------------------------------------------------------------------

cmd_start() {
  local goal="" roles="architect,executor,thrifty" slug="" base="" reap=0
  local create_args=() host="" project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --roles) roles="${2:?}"; shift 2 ;;
      --name) slug="${2:?}"; shift 2 ;;
      --base-branch) base="${2:?}"; shift 2 ;;
      --repo) create_args+=(--repo "${2:?}"); shift 2 ;;
      --project) project="${2:?}"; shift 2 ;;
      --host) host="${2:?}"; shift 2 ;;
      --reap) reap=1; shift ;;
      --timeout-ms) REAP_TIMEOUT_MS="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "Unknown: $1" >&2; exit 1 ;;
      *)
        if [[ -z "$goal" ]]; then goal="$1"; else echo "Unknown: $1 (goal already set)" >&2; exit 1; fi
        shift ;;
    esac
  done
  if [[ -z "${goal// }" ]]; then echo "race start: a goal is required" >&2; usage; exit 1; fi
  if [[ -n "$host" && -z "$project" ]]; then echo "--host needs --project <id>" >&2; exit 1; fi
  if [[ -n "$project" ]]; then
    create_args+=(--project "$project")
    [[ -n "$host" ]] && create_args+=(--host "$host")
  elif [[ ${#create_args[@]} -eq 0 ]]; then
    # Orca infers the repo from cwd otherwise; the coordinator may run this
    # from anywhere, so name the project root explicitly.
    create_args=(--repo "path:$ROOT")
  fi

  local role_list=() r
  IFS=',' read -r -a role_list <<<"$roles"
  if [[ ${#role_list[@]} -lt 2 ]]; then echo "race start: need at least 2 roles" >&2; exit 1; fi
  for r in "${role_list[@]}"; do validate_role "$r" || exit 1; done

  # Same refusal as orca-dispatch-role.sh: a dispatch with no Run bound can
  # never deliver its worker_done.
  local run_id
  run_id="$(resolve_run_id)"
  if [[ -z "$run_id" ]]; then
    echo "orca-race.sh: no Run bound to this terminal — refusing to start a race." >&2
    run_scope_hint >&2
    exit 1
  fi

  if [[ -z "$base" ]]; then
    base="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [[ -z "$base" || "$base" == "HEAD" ]] && base="main"
  fi
  if [[ -z "$slug" ]]; then
    slug="$(printf '%s' "$goal" | tr -cs 'A-Za-z0-9' '-' | tr 'A-Z' 'a-z' | sed -E 's/^-+//; s/-+$//' | cut -c1-24)"
    [[ -z "$slug" ]] && slug="race"
  fi
  local race_id
  race_id="race-$(date +%Y%m%d%H%M%S)-$$"

  # Globals read by seed()/create_role() in orca-roles-lib.sh.
  if [[ -f "$ROOT/AGENTS.md" ]]; then
    CONSTRAINTS="Read and follow AGENTS.md in the project root."
  elif [[ -f "$ROOT/CLAUDE.md" ]]; then
    CONSTRAINTS="Read and follow CLAUDE.md in the project root."
  else
    # shellcheck disable=SC2034
    CONSTRAINTS="Follow repository conventions; never commit secrets."
  fi

  echo "race $race_id: ${#role_list[@]} seats, base=$base, run=$run_id"
  local i=0 started=0 role wt path branch wt_id title model agent handle
  local full_spec create_json task_id worker_json dispatch_id
  for role in "${role_list[@]}"; do
    i=$((i + 1))
    echo "--- seat $i/${#role_list[@]}: $role"
    if ! wt="$(worktree_create "$slug-$i" "$base" "$race_id" "$i" ${create_args[@]+"${create_args[@]}"})"; then
      echo "race: worktree create failed for seat $i ($role) — see $RACE_LEDGER (kind=worktree_create)" >&2
      race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=start_failed" "reason=worktree-create" "baseRef=$base" "goal=$goal"
      continue
    fi
    wt_id="${wt%%$'\t'*}"; path="$(printf '%s' "$wt" | cut -f2)"; branch="${wt##*$'\t'}"
    echo "  worktree $path ($branch)"

    IFS=$'\t' read -r title model agent < <(role_meta "$role")
    title="$race_id-$role"
    # create_role only registers trust for the project root (see its
    # LIMITATION note); a codex seat boots in the NEW checkout, so register
    # that path too, before the terminal exists.
    if [[ "$(role_cli "$role")" == "codex" ]]; then codex_trust_ensure "$path"; fi
    # shellcheck disable=SC2034  # read by create_role
    WORKTREE="path:$path"
    if ! handle="$(create_role "$title" "$(role_launch_cmd "$role")" "$role")"; then
      race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=start_failed" "reason=terminal-create" \
        "worktreeId=$wt_id" "path=$path" "branch=$branch" "baseRef=$base" "goal=$goal"
      continue
    fi
    wait_idle "$handle"
    if ! seed "$handle" "$role" "$model" "$(role_fallback_body "$role")"; then
      race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=start_failed" "reason=seed" \
        "worktreeId=$wt_id" "path=$path" "branch=$branch" "baseRef=$base" "handle=$handle" "goal=$goal"
      continue
    fi
    orca terminal wait --terminal "$handle" --for tui-idle --timeout-ms 90000 --json >/dev/null 2>&1 || true
    if ! terminal_wait_ready "$handle" "$agent"; then
      echo "race: seat $i ($role) never showed a ready screen — not dispatching" >&2
      race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=start_failed" "reason=not-ready" \
        "worktreeId=$wt_id" "path=$path" "branch=$branch" "baseRef=$base" "handle=$handle" "goal=$goal"
      continue
    fi

    full_spec="$(build_role_spec "$role" "$goal
You are seat $i of ${#role_list[@]} in a race: other roles work on the same goal in their own worktrees. Work only inside this worktree ($path); do not touch other checkouts." "$ORCH/personas")"
    create_json="$(orca orchestration task-create --run "$run_id" --task-title "race $slug #$i $role" \
      --display-name "[race:$role]" --spec "$full_spec" --json)" || create_json=""
    task_id="$(parse_task_id "$create_json" 2>/dev/null || true)"
    if [[ -z "$task_id" ]]; then
      echo "race: task-create failed for seat $i ($role)" >&2
      warn_if_legacy_read_only "$create_json" "task-create for race seat $i"
      race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=start_failed" "reason=task-create" \
        "worktreeId=$wt_id" "path=$path" "branch=$branch" "baseRef=$base" "handle=$handle" "goal=$goal"
      continue
    fi
    # worker-start on OUR pre-created tab, scoped to the seat's worktree (the
    # CLI's own note: "when reusing --terminal, pass --worktree for that
    # terminal"). Measured in spike S3.
    worker_json="$(orca orchestration worker-start --run "$run_id" --task "$task_id" \
      --terminal "$handle" --worktree "path:$path" --json)" || worker_json=""
    dispatch_id="$(printf '%s' "$worker_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
r = d.get("result") or d
print(r.get("dispatchId") or (r.get("dispatch") or {}).get("id") or "")
' 2>/dev/null || true)"
    if [[ -z "$dispatch_id" ]]; then
      echo "race: worker-start failed for seat $i ($role) task=$task_id" >&2
      race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=start_failed" "reason=worker-start" \
        "worktreeId=$wt_id" "path=$path" "branch=$branch" "baseRef=$base" "handle=$handle" "taskId=$task_id" "goal=$goal"
      continue
    fi
    race_seat_append "raceId=$race_id" "seat=$i" "role=$role" "status=running" \
      "worktreeId=$wt_id" "path=$path" "branch=$branch" "baseRef=$base" "handle=$handle" \
      "taskId=$task_id" "dispatchId=$dispatch_id" "goal=$goal"
    # no_reap = !reap: seats retain their tab by default (see header).
    register_dispatch_and_reap "$LEDGER_FILE" "$task_id" "$dispatch_id" "$role" "$handle" $((1 - reap)) "$REAP_TIMEOUT_MS"
    orca worktree set --worktree "path:$path" --comment "race $race_id seat $i/${#role_list[@]}: $role" --json >/dev/null 2>&1 || true
    started=$((started + 1))
    echo "  seat $i dispatched: task=$task_id dispatch=$dispatch_id handle=$handle"
  done

  echo ""
  echo "race_id=$race_id started=$started/${#role_list[@]}"
  echo "  status: .orca/orchestration/or race status $race_id"
  echo "  pick:   .orca/orchestration/or race pick $race_id <seat>"
  if [[ "$started" -lt 2 ]]; then
    echo "race: fewer than 2 seats started — no race. Clean up with: or race abort $race_id" >&2
    exit 2
  fi
}

# --- status / list ----------------------------------------------------------

cmd_status() {
  local race_id="${1:-}"
  [[ -n "$race_id" ]] || { usage; exit 1; }
  local rows seat role status path handle task dispatch base ws dstat changed diffstat
  rows="$(race_seats "$race_id")"
  if [[ -z "$rows" ]]; then echo "race: no seats for $race_id in $RACE_LEDGER" >&2; exit 1; fi
  printf '%-4s %-10s %-13s %-10s %-9s %-8s %s\n' seat role status worker dispatch changed path
  while IFS=$'\t' read -r seat role status path handle task dispatch base; do
    ws="-"; dstat="-"; changed="-"; diffstat=""
    if [[ "$dispatch" != "-" && "$status" != "removed" ]]; then
      IFS=$'\t' read -r ws dstat < <(worker_show_state "$dispatch" 2>/dev/null || printf '?\t?\n')
    fi
    if [[ "$path" != "-" && -d "$path" ]] && git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
      changed="$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ' || true)"
      diffstat="$(git -C "$path" diff --stat "$base...HEAD" 2>/dev/null | tail -1 | sed -E 's/^ +//' || true)"
    fi
    printf '%-4s %-10s %-13s %-10s %-9s %-8s %s\n' "$seat" "$role" "$status" "${ws:-?}" "${dstat:-?}" "$changed" "$path"
    if [[ -n "$diffstat" ]]; then printf '     committed vs %s: %s\n' "$base" "$diffstat"; fi
  done <<<"$rows"
  return 0
}

cmd_list() {
  [[ -f "$RACE_LEDGER" ]] || { echo "(no races yet)"; return 0; }
  python3 - "$RACE_LEDGER" <<'PY'
import json, sys
races = {}
order = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("kind") != "seat":
            continue
        rid = row.get("raceId")
        if rid not in races:
            races[rid] = {"goal": row.get("goal") or "", "seats": {}}
            order.append(rid)
        races[rid]["seats"][row.get("seat")] = row.get("status")
for rid in order:
    r = races[rid]
    summary = ", ".join("%s:%s" % (s, st) for s, st in sorted(r["seats"].items(), key=lambda kv: str(kv[0])))
    print("%s  [%s]  %s" % (rid, summary, r["goal"][:60]))
PY
}

# --- pick / finish / abort ----------------------------------------------------

cmd_pick() {
  local race_id="${1:-}" winner="${2:-}"
  [[ -n "$race_id" && -n "$winner" ]] || { usage; exit 1; }
  local rows seat role status path handle task dispatch base failures=0 found=0 winner_path=""
  rows="$(race_seats "$race_id")"
  if [[ -z "$rows" ]]; then echo "race: no seats for $race_id" >&2; exit 1; fi
  while IFS=$'\t' read -r seat role status path handle task dispatch base; do
    if [[ "$seat" == "$winner" ]]; then
      found=1; winner_path="$path"
      continue
    fi
    [[ "$status" == "removed" ]] && continue
    [[ "$status" == "rm_failed" ]] && echo "race: seat $seat previously failed to remove — retrying"
    seat_remove "$race_id" "$seat" "$path" "$dispatch" "$task" || failures=$((failures + 1))
  done <<<"$rows"
  if [[ "$found" -eq 0 ]]; then echo "race: seat $winner is not in $race_id" >&2; exit 1; fi
  race_seat_mark "$race_id" "$winner" winner
  if [[ "$winner_path" != "-" ]]; then
    orca worktree set --worktree "path:$winner_path" --workspace-status in-review --json >/dev/null 2>&1 || true
    orca file open-changed --mode diff --worktree "path:$winner_path" --json >/dev/null 2>&1 \
      || echo "race: could not open the winner's diff (orca file open-changed) — open it from the worktree tab" >&2
  fi
  echo "race $race_id: seat $winner kept ($winner_path). Its agent tab is still open — review in the diff viewer, use Send to agent, then commit/push from Orca."
  echo "  release the tab when done: .orca/orchestration/or race finish $race_id"
  if [[ "$failures" -gt 0 ]]; then
    echo "race: $failures seat(s) could not be removed — see 'or s' and $RACE_LEDGER (rm_failed)" >&2
    exit 1
  fi
}

cmd_finish() {
  local race_id="${1:-}"
  [[ -n "$race_id" ]] || { usage; exit 1; }
  local rows seat role status path handle task dispatch base rc=0 outcome
  rows="$(race_seats "$race_id")"
  while IFS=$'\t' read -r seat role status path handle task dispatch base; do
    [[ "$status" == "winner" ]] || continue
    outcome="$(worker_release_or_close "$dispatch" "$handle")" || true
    case "$outcome" in
      released|closed)
        race_seat_mark "$race_id" "$seat" finished "tab=$outcome"
        [[ "$task" != "-" ]] && dispatch_ledger_mark "$task" "$outcome"
        echo "race: winner seat $seat tab $outcome; worktree kept at $path" ;;
      *)
        race_seat_mark "$race_id" "$seat" close_failed "tab=${outcome:-unknown}"
        [[ "$task" != "-" ]] && dispatch_ledger_mark "$task" "${outcome:-close_failed}"
        echo "race: could not release winner tab $handle (${outcome:-unknown})" >&2
        rc=1 ;;
    esac
  done <<<"$rows"
  exit "$rc"
}

cmd_abort() {
  local race_id="${1:-}" include_winner=0
  [[ -n "$race_id" ]] || { usage; exit 1; }
  shift
  [[ "${1:-}" == "--include-winner" ]] && include_winner=1
  local rows seat role status path handle task dispatch base failures=0
  rows="$(race_seats "$race_id")"
  if [[ -z "$rows" ]]; then echo "race: no seats for $race_id" >&2; exit 1; fi
  while IFS=$'\t' read -r seat role status path handle task dispatch base; do
    case "$status" in
      removed) continue ;;
      winner|finished)
        if [[ "$include_winner" -eq 0 ]]; then
          echo "race: seat $seat is the winner — kept (pass --include-winner to remove it too)"
          continue
        fi ;;
    esac
    if [[ "$path" == "-" ]]; then
      # A seat that failed before its worktree existed has nothing to remove.
      race_seat_mark "$race_id" "$seat" removed "reason=nothing-created"
      continue
    fi
    seat_remove "$race_id" "$seat" "$path" "$dispatch" "$task" || failures=$((failures + 1))
  done <<<"$rows"
  if [[ "$failures" -gt 0 ]]; then
    echo "race: $failures seat(s) could not be removed — see $RACE_LEDGER (rm_failed)" >&2
    exit 1
  fi
  echo "race $race_id aborted."
}

# --- main -------------------------------------------------------------------

[[ $# -ge 1 ]] || { usage; exit 1; }
SUB="$1"; shift
case "$SUB" in
  start)  cmd_start "$@" ;;
  status) cmd_status "$@" ;;
  pick)   cmd_pick "$@" ;;
  finish) cmd_finish "$@" ;;
  abort)  cmd_abort "$@" ;;
  list)   cmd_list ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown race subcommand: $SUB" >&2; usage; exit 1 ;;
esac
