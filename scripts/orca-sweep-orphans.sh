#!/usr/bin/env bash
# Orphan sweeper + dead-man watchdog for --persist debate tabs.
#
# Two independent capabilities in one file, because they solve the same
# problem (an abandoned, permission-bypassed Orca terminal with no owner)
# from two different angles:
#
#   (default) sweep mode — run at any time. Looks at
#   $ORCH/terminal-journal.jsonl (the durable record written by create_role
#   BEFORE its response is even parsed — see orca-roles-lib.sh) for handles
#   that are: created under one of OUR launch titles, NOT the current value
#   of any role in handles.json, NOT owned by a live (fresh-heartbeat)
#   debate lock, and older than an age guard. It never acts on a handle it
#   cannot positively identify as ours, and it never acts on a
#   terminal_is_live() result of 2 (undetermined) — see close_handle_if_live
#   below. Default is REPORT-ONLY; pass --close to actually close anything.
#   This polarity is deliberate: a tool that can run "at any time" against
#   possibly-ambiguous, journal-derived candidates should default to the
#   safe side. --dry-run is an explicit synonym for the (also safe) default.
#
#   --watchdog mode — started once per debate by orca-debate.sh
#   (debate_watchdog_start, in orca-debate-lib.sh). Owns a single
#   $ORCH/debate-locks/<slug>.json lock file and polls whether the
#   recorded owner pid is still alive. While alive, it refreshes the
#   lock's heartbeatAt on the owner's behalf (see orca-debate-lib.sh's
#   comment on why the owner cannot practically do this itself — it spends
#   most of a round blocked on a child process). The moment the owner is
#   gone, it closes every handle the lock knows about and exits — a
#   genuinely separate background process (not a child the driver keeps
#   alive), so `kill -9` on the driver's specific pid does not take the
#   watchdog down with it. Default here is the OPPOSITE polarity from
#   sweep mode: it actually closes by default (that is the entire point of
#   a dead-man's switch), and --dry-run opts OUT of closing for
#   tests/demos. See the "Safety" section of task-2-report.md for the full
#   argument for why these two defaults intentionally differ.
#
# Usage:
#   orca-sweep-orphans.sh [--close|--dry-run] [--max-age-seconds N]
#                         [--orch-dir PATH] [--journal PATH]
#                         [--handles-file PATH] [--locks-dir PATH]
#   orca-sweep-orphans.sh --watchdog --slug SLUG --owner-pid PID
#                         [--dry-run] [--poll-seconds N] [--max-close-attempts N]
#                         [--orch-dir PATH] [--locks-dir PATH]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"

MODE=sweep
SLUG=""
OWNER_PID=""
ORCH_DIR=""
JOURNAL=""
HANDLES_FILE=""
LOCKS_DIR=""
MAX_AGE_SECONDS=1200
POLL_SECONDS=20
MAX_CLOSE_ATTEMPTS=5
ACT=""   # resolved to a mode-specific default after parsing — see below

usage() {
  cat <<'EOF'
Usage:
  orca-sweep-orphans.sh [--close|--dry-run] [--max-age-seconds N]
                        [--orch-dir PATH] [--journal PATH]
                        [--handles-file PATH] [--locks-dir PATH]
  orca-sweep-orphans.sh --watchdog --slug SLUG --owner-pid PID
                        [--dry-run] [--poll-seconds N] [--max-close-attempts N]
                        [--orch-dir PATH] [--locks-dir PATH]

Sweep mode (default): reports terminal-journal.jsonl handles that are
untracked (absent from handles.json AND from any live debate lock), old
enough to rule out a still-in-progress create, and created under a title we
recognize. Never closes anything unless --close is given.

Watchdog mode: a long-running background process that owns one debate's
lock file (started by orca-debate.sh, not meant to be run by hand). Closes
its owned handles the moment the recorded owner pid is no longer alive.
Closes by default; pass --dry-run to only report what it would do.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watchdog) MODE=watchdog; shift ;;
    --slug) SLUG="${2:?}"; shift 2 ;;
    --owner-pid) OWNER_PID="${2:?}"; shift 2 ;;
    --orch-dir) ORCH_DIR="${2:?}"; shift 2 ;;
    --journal) JOURNAL="${2:?}"; shift 2 ;;
    --handles-file) HANDLES_FILE="${2:?}"; shift 2 ;;
    --locks-dir) LOCKS_DIR="${2:?}"; shift 2 ;;
    --max-age-seconds) MAX_AGE_SECONDS="${2:?}"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="${2:?}"; shift 2 ;;
    --max-close-attempts) MAX_CLOSE_ATTEMPTS="${2:?}"; shift 2 ;;
    --close) ACT=1; shift ;;
    --dry-run) ACT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

ORCH="${ORCH_DIR:-$(cd "$HERE/.." && pwd)}"
JOURNAL="${JOURNAL:-$ORCH/terminal-journal.jsonl}"
HANDLES_FILE="${HANDLES_FILE:-$ORCH/handles.json}"
LOCKS_DIR="${LOCKS_DIR:-$ORCH/debate-locks}"

if [[ -z "$ACT" ]]; then
  if [[ "$MODE" == "watchdog" ]]; then ACT=1; else ACT=0; fi
fi

if [[ "$MODE" == "watchdog" ]]; then
  if [[ -z "$SLUG" || -z "$OWNER_PID" ]]; then
    echo "--watchdog requires --slug and --owner-pid" >&2
    usage
    exit 1
  fi
fi

# --- shared: check + (maybe) close one handle, gated on terminal_is_live's
# 3-state contract. Exit code mirrors terminal_is_live (0 live, 1 dead, 2
# undetermined) so callers can distinguish "handled" from "leave it, maybe
# retry later" without a second, possibly-inconsistent liveness check.
close_handle_if_live() {
  local h="$1" label="$2" do_close="$3" live_rc=0
  terminal_is_live "$h" || live_rc=$?
  case "$live_rc" in
    2)
      echo "sweep: $label ($h): liveness undetermined — leaving alone (never act on ambiguity)"
      ;;
    1)
      echo "sweep: $label ($h): already gone — nothing to do"
      ;;
    0)
      if [[ "$do_close" -eq 1 ]]; then
        echo "sweep: $label ($h): live and orphaned — closing"
        if orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1 \
          || orca terminal close --terminal "$h" --json >/dev/null 2>&1; then
          echo "sweep: $label ($h): closed"
        else
          echo "sweep: $label ($h): close returned non-zero (may already be gone)"
        fi
      else
        echo "sweep: $label ($h): live and orphaned — WOULD CLOSE (pass --close to act)"
      fi
      ;;
  esac
  return "$live_rc"
}

# ---------------------------------------------------------------------------
# Sweep mode
# ---------------------------------------------------------------------------
sweep_mode() {
  local role_keys="architect executor thrifty ui reviewer fallback debater_claude debater_codex debater_grok debater_gemini"
  local titles_file scratch rk
  titles_file="$(mktemp)"
  for rk in $role_keys; do
    role_meta "$rk" 2>/dev/null | cut -f1
  done > "$titles_file"

  scratch="$(mktemp)"
  python3 - "$JOURNAL" "$HANDLES_FILE" "$LOCKS_DIR" "$titles_file" "$MAX_AGE_SECONDS" <<'PY' >"$scratch"
import json, os, sys, datetime, glob

journal_path, handles_path, locks_dir, titles_path, max_age = sys.argv[1:6]
max_age = float(max_age)
now = datetime.datetime.now(datetime.timezone.utc)

def field(s):
    # Never emit a truly-empty TSV field. Confirmed empirically: bash
    # classifies tab as IFS "blank" regardless of how IFS is set, so
    # `IFS=$'\t' read` collapses a RUN of tabs (i.e. an empty field
    # between two adjacent tab delimiters) into a single delimiter instead
    # of yielding an empty field — every field after the empty one then
    # shifts left by one, and the last named variable silently ends up
    # empty. This bites exactly the role="" case (a journal entry with
    # role=null — precisely the bootstrap-partial-failure orphan this
    # task exists to sweep) and was caught by an ABORT-path test whose
    # log message came out truncated. The actual close decision downstream
    # only ever reads the handle/title fields (never role/reason), so this
    # was never a safety issue — but it is a real, previously-undetected
    # bug that any of this row's callers could hit reading role/reason.
    # "-" is a value no real title/role/reason ever equals.
    return s if s else "-"

known_titles = set()
try:
    with open(titles_path) as f:
        for line in f:
            line = line.strip()
            if line:
                known_titles.add(line)
except Exception:
    pass

def walk_strings(obj):
    if isinstance(obj, dict):
        for v in obj.values():
            for s in walk_strings(v):
                yield s
    elif isinstance(obj, list):
        for v in obj:
            for s in walk_strings(v):
                yield s
    elif isinstance(obj, str):
        yield obj

tracked = set()
handles_unreadable = False
if os.path.exists(handles_path):
    # A missing handles.json is a normal, safe case (nothing has ever been
    # tracked, so an empty "tracked" set is correct) — but a handles.json
    # that EXISTS and fails to parse is a different, more concerning
    # situation: handles_set (orca-roles-lib.sh) writes it with a plain
    # `open(path, "w")`, not an atomic temp-file-plus-rename, so a read
    # landing mid-write (or a corrupted/hand-edited file) can produce
    # exactly this. Treating that the same as "nothing is tracked" would be
    # the wrong fail-safe direction for a tool whose entire purpose is
    # never closing a terminal it does not own — a currently-in-use
    # primary-role terminal (architect/executor/etc., which unlike a
    # debate tab has no lock-based protection at all) could then look
    # exactly like an untracked orphan. So this aborts the whole run
    # instead of silently sweeping with an empty tracked set.
    try:
        hd = json.load(open(handles_path))
        for s in walk_strings(hd):
            tracked.add(s)
    except Exception:
        handles_unreadable = True

if handles_unreadable:
    print("ABORT\t(handles-unreadable)\t%s\t%s\t%s exists but could not be parsed as JSON, refusing to sweep rather than treat everything in it as untracked" % (handles_path, field(""), handles_path))
    sys.exit(0)

def parse_time(text):
    try:
        t = datetime.datetime.fromisoformat(text)
        if t.tzinfo is None:
            t = t.replace(tzinfo=datetime.timezone.utc)
        return t
    except Exception:
        return None

def pid_alive(pid_val):
    # True unless we can PROVE the pid is gone (ProcessLookupError). Every
    # other outcome — unparseable pid, PermissionError (process exists,
    # just owned by someone else), or any other OSError — defaults to
    # "alive", matching this whole tool's bias: never treat an inability
    # to determine liveness as license to act.
    try:
        pid = int(pid_val)
    except Exception:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except Exception:
        return True
    return True

protected = set()
stale_candidates = {}
for lf in sorted(glob.glob(os.path.join(locks_dir, "*.json"))):
    try:
        d = json.load(open(lf))
        hb = parse_time(d.get("heartbeatAt", ""))
        ttl = float(d.get("ttlSeconds", 0))
        handles = list(d.get("handles") or [])
        pid = d.get("pid")
        slug = d.get("slug") or os.path.basename(lf)[:-5]
    except Exception:
        continue
    if hb is None:
        continue
    # Fold in the not-yet-merged sidecar too: a handle a --persist dispatch
    # just registered can sit there for up to one whole poll cycle before
    # this lock's own watchdog folds it into "handles" — reading only
    # "handles" would make a handle look unclaimed during that window.
    sidecar_path = lf[:-5] + ".handles.jsonl"
    if os.path.exists(sidecar_path):
        try:
            with open(sidecar_path) as sf:
                for line in sf:
                    h = line.strip()
                    if h and h not in handles:
                        handles.append(h)
        except Exception:
            pass
    age = (now - hb).total_seconds()
    if age < ttl:
        for h in handles:
            protected.add(h)
    else:
        for h in handles:
            if h not in stale_candidates:
                stale_candidates[h] = (slug, pid)

handle_title = {}
journal_candidates = []
try:
    with open(journal_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            handle = row.get("handle")
            title = row.get("title") or ""
            role = row.get("role") or ""
            created_raw = row.get("createdAt") or ""
            if handle:
                handle_title[handle] = title
            if not handle:
                print("SKIP\t(no-handle)\t%s\t%s\tunclosable, no handle recorded" % (field(title), field(role)))
                continue
            if title not in known_titles:
                print("SKIP\t%s\t%s\t%s\tunrelated title, not ours" % (handle, field(title), field(role)))
                continue
            if handle in tracked:
                continue
            if handle in protected:
                continue
            created = parse_time(created_raw)
            age_ok = created is not None and (now - created).total_seconds() >= max_age
            if not age_ok:
                print("SKIP\t%s\t%s\t%s\ttoo young, guard against mid-creation race" % (handle, field(title), field(role)))
                continue
            journal_candidates.append((handle, title, role, created_raw))
except FileNotFoundError:
    pass

seen = set()
for handle, title, role, created_raw in journal_candidates:
    seen.add(handle)
    print("CANDIDATE\t%s\t%s\t%s\tjournal-orphan createdAt=%s" % (handle, field(title), field(role), created_raw))

for handle, (slug, owner_pid) in stale_candidates.items():
    if handle in seen:
        continue
    # Deliberately NOT gated on "handle in tracked": orca-close-role.sh does
    # not edit handles.json on close ("next dispatch recreates via
    # ensure_terminal"), so a debater's handle sits there permanently from
    # creation, tracked forever whether its terminal is alive, closed, or
    # abandoned — presence in handles.json carries no liveness information
    # for this class of handle and cannot be the protection rule. A stale
    # lock naming a handle is the opposite of protection: it is the
    # strongest evidence available that whoever was responsible for it is
    # gone. What DOES protect it: something else CURRENTLY claiming
    # responsibility.
    if handle in protected:
        print("SKIP\t%s\t%s\t%s\tstale lock %s but also claimed by a different, still-fresh lock" % (handle, field(handle_title.get(handle, "(unknown)")), field(""), slug))
        continue
    if pid_alive(owner_pid):
        print("SKIP\t%s\t%s\t%s\tstale lock %s but owner pid=%s is still alive (its watchdog may have died, not the debate itself)" % (handle, field(handle_title.get(handle, "(unknown)")), field(""), slug, owner_pid))
        continue
    title = handle_title.get(handle, "(unknown)")
    print("CANDIDATE\t%s\t%s\t%s\tstale-lock slug=%s" % (handle, field(title), field(""), slug))
PY

  local n_candidates=0 n_closed=0 n_gone=0 n_undetermined=0 aborted=0
  local kind handle title role reason hrc
  while IFS=$'\t' read -r kind handle title role reason; do
    [[ -z "$kind" ]] && continue
    case "$kind" in
      ABORT)
        echo "sweep: ABORTING — $reason" >&2
        aborted=1
        ;;
      SKIP)
        echo "sweep: SKIP $handle ($title): $reason"
        ;;
      CANDIDATE)
        n_candidates=$((n_candidates + 1))
        hrc=0
        close_handle_if_live "$handle" "$title" "$ACT" || hrc=$?
        case "$hrc" in
          0) n_closed=$((n_closed + 1)) ;;
          1) n_gone=$((n_gone + 1)) ;;
          2) n_undetermined=$((n_undetermined + 1)) ;;
        esac
        ;;
    esac
  done < "$scratch"
  rm -f "$scratch" "$titles_file"

  if [[ "$aborted" -eq 1 ]]; then
    echo "sweep: aborted — closed nothing this run" >&2
    return 0
  fi

  if [[ "$ACT" -eq 1 ]]; then
    echo "sweep: candidates=$n_candidates closed=$n_closed already-gone=$n_gone undetermined-left-alone=$n_undetermined"
  else
    echo "sweep: candidates=$n_candidates would-close=$n_closed already-gone=$n_gone undetermined-left-alone=$n_undetermined (report-only — pass --close to act)"
  fi
}

# ---------------------------------------------------------------------------
# Watchdog mode
# ---------------------------------------------------------------------------

sleep_interruptible() {
  # $1=total_seconds. Chunks a long sleep into 1s pieces instead of one
  # `sleep N` call. Confirmed empirically on this repo's bash (3.2.57,
  # macOS): a trap on a signal bash has already registered does NOT
  # preempt a currently-running external command — bash only checks for
  # and runs a pending trap once control returns to its own main loop
  # (i.e., once the foreground command completes), a signal arriving
  # mid-`sleep 20` is not acted on until that sleep's full 20s elapses.
  # Reproduced directly: `trap ... TERM` + `sleep 3` in a loop, SIGTERM
  # sent 1s into the sleep, trap did not fire until ~3s (when the sleep
  # naturally returned), never sooner. Chunking bounds that worst case to
  # ~1s regardless of $1, which is what makes debate_watchdog_stop's
  # SIGTERM actually prompt rather than "prompt, up to a full poll
  # interval later."
  local total="$1" elapsed=0
  while [[ "$elapsed" -lt "$total" ]]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

run_watchdog() {
  local lock_file="$LOCKS_DIR/$SLUG.json"
  trap 'echo "watchdog[$SLUG]: received TERM — standing down without acting (owner exited normally)"; exit 0' TERM

  echo "watchdog[$SLUG]: watching owner pid=$OWNER_PID lock=$lock_file"

  while true; do
    if [[ ! -f "$lock_file" ]]; then
      echo "watchdog[$SLUG]: lock file gone — nothing left to own, exiting"
      exit 0
    fi
    local cur_pid
    cur_pid="$(lock_pid "$lock_file")"
    if [[ "$cur_pid" != "$OWNER_PID" ]]; then
      echo "watchdog[$SLUG]: lock is now owned by pid=$cur_pid (not us, pid=$OWNER_PID) — standing down, closing nothing"
      exit 0
    fi

    if kill -0 "$OWNER_PID" 2>/dev/null; then
      lock_merge_and_refresh "$lock_file" || echo "watchdog[$SLUG]: (warn) could not refresh heartbeat" >&2
      sleep_interruptible "$POLL_SECONDS"
      continue
    fi

    echo "watchdog[$SLUG]: owner pid=$OWNER_PID is gone — closing owned tabs"
    break
  done

  # One last merge: a handle registered in the sidecar just before the owner
  # died must not be missed because it never made it into "handles" before
  # we stopped refreshing.
  lock_merge_and_refresh "$lock_file" || true

  local attempt=0 pending_file
  pending_file="$(mktemp)"
  lock_handles "$lock_file" > "$pending_file"

  while [[ "$attempt" -lt "$MAX_CLOSE_ATTEMPTS" ]] && [[ -s "$pending_file" ]]; do
    cur_pid="$(lock_pid "$lock_file")"
    if [[ "$cur_pid" != "$OWNER_PID" ]]; then
      echo "watchdog[$SLUG]: ownership changed mid-close (now pid=$cur_pid) — standing down without further action"
      rm -f "$pending_file"
      exit 0
    fi
    local still_file h hrc
    still_file="$(mktemp)"
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      # ensure_terminal reuses a live role terminal globally, so two
      # different debates can legitimately share one debater's underlying
      # handle (each having registered it into its own, separate lock).
      # Before closing, confirm no OTHER fresh lock (with a confirmed-alive
      # owner — see lock_handle_claimed_elsewhere's own comment for why
      # freshness alone is not enough) still actively depends on this
      # handle. Treated as resolved, not retried: "someone else owns this"
      # is a fact this cycle already has full information about, not a
      # liveness ambiguity that might resolve differently later.
      if lock_handle_claimed_elsewhere "$LOCKS_DIR" "$h" "$lock_file"; then
        echo "watchdog[$SLUG]: $h is also claimed by a different, still-active debate — leaving it alone"
        continue
      fi
      hrc=0
      close_handle_if_live "$h" "debate:$SLUG" "$ACT" || hrc=$?
      [[ "$hrc" -eq 2 ]] && printf '%s\n' "$h" >> "$still_file"
    done < "$pending_file"
    mv "$still_file" "$pending_file"
    attempt=$((attempt + 1))
    [[ -s "$pending_file" ]] && [[ "$attempt" -lt "$MAX_CLOSE_ATTEMPTS" ]] && sleep_interruptible "$POLL_SECONDS"
  done

  if [[ -s "$pending_file" ]]; then
    echo "watchdog[$SLUG]: giving up after $MAX_CLOSE_ATTEMPTS attempts; still undetermined: $(tr '\n' ' ' < "$pending_file") — leaving the lock in place as a breadcrumb for orca-sweep-orphans.sh's sweep mode"
  else
    echo "watchdog[$SLUG]: all owned handles resolved — removing lock"
    lock_remove "$lock_file"
  fi
  rm -f "$pending_file"
  exit 0
}

if [[ "$MODE" == "watchdog" ]]; then
  mkdir -p "$LOCKS_DIR"
  run_watchdog
else
  sweep_mode
fi
