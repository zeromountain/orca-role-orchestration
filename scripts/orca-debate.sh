#!/usr/bin/env bash
# Drive a three-round multi-model idea debate and assemble its transcript.
#
#   R1 propose   → each model researches and proposes independently
#   R2 critique  → each model attacks the others' proposals, anonymized
#   R3 converge  → each model narrows to niche candidates with kill conditions
#
# Debater tabs stay open between rounds (dispatch --persist) so each participant
# remembers its own earlier statements; this script closes them on exit.
#
# Usage:
#   orca-debate.sh --topic "…" | --topic-file <f>
#                  [--slug s] [--rounds 3] [--debaters claude,codex,grok,gemini]
#                  [--judge <role>] [--timeout-ms N] [--keep-tabs] [--dry-run]
#   orca-debate.sh --build-transcript <debate-dir>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
# shellcheck source=orca-debate-lib.sh
source "$HERE/orca-debate-lib.sh"
HANDLES_FILE="$ORCH/handles.json"

TOPIC=""
TOPIC_FILE=""
SLUG=""
ROUNDS=3
DEBATERS="$DEBATERS_DEFAULT"
JUDGE=""
TIMEOUT_MS=""
KEEP_TABS=0
DRY_RUN=0
DIR_ROOT="$ORCH/debates"
BUILD_ONLY=""
LOCK_TTL_SECONDS="$DEBATE_LOCK_TTL_SECONDS_DEFAULT"
# Task 3: label map + manifest are driver-only state and live OUTSIDE the
# debate directory (never inside $DIR_ROOT/<slug>/) — nothing a debater can
# glob or read may ever reveal a short name. Overridable so tests (and a
# standalone --build-transcript invocation) can sandbox them without having
# to copy this whole script tree, matching --dir-root's existing precedent.
LABELS_DIR="$ORCH/debate-labels"
MANIFESTS_DIR="$ORCH/debate-manifests"
EPHEMERAL_LABEL_MAP=""

# Per-round defaults: R1 carries the research obligation and gets longer.
R1_TIMEOUT_MS=1800000
RN_TIMEOUT_MS=900000

usage() {
  cat <<'EOF'
Usage:
  orca-debate.sh --topic "…" | --topic-file <file>
                 [--slug <s>] [--rounds 1|2|3] [--debaters claude,codex,grok,gemini]
                 [--judge <role>] [--timeout-ms N] [--keep-tabs] [--dry-run]
                 [--dir-root <path>] [--lock-ttl-seconds N]
  orca-debate.sh --build-transcript <debate-dir>

  --judge <role>   Dispatch this role to write the decision document
                   (default: leave it to the coordinator).
  --keep-tabs      Do not close debater tabs on exit (debugging).
  --dry-run        Print every round's specs; create no terminals. Never
                   writes the real label map (uses a throwaway one instead).
  --lock-ttl-seconds N  Dead-man watchdog staleness threshold (default 1800 —
                   see orca-debate-lib.sh for reasoning). Mainly for tests.
  --labels-dir <path>     Where the per-slug label map lives (default
                   $ORCH/debate-labels). Driver-only state; mainly for tests.
  --manifests-dir <path>  Where per-round manifests live (default
                   $ORCH/debate-manifests). Driver-only state; mainly for tests.
EOF
}

build_transcript() {
  # $1=debate dir
  #
  # This is the ONE deliberate place a short model name is meant to appear
  # (see "Ambiguity resolved" in task-3-report.md): the transcript is for the
  # human, never read by a debater (no round spec ever points at it, and it
  # is only written once the debate itself has concluded), so it re-attributes
  # each round-*/​<LABEL>.md file back to its real short name via the external
  # label map. Falls back to printing the raw label if the map is missing or
  # unreadable, or if its own recorded slug doesn't match this directory's
  # (debate_short_for_label's guard) — e.g. this directory was copied
  # elsewhere, or its label map was later rebuilt for a different roster.
  local dir="$1" out="$1/transcript.md" round file label short slug label_map
  slug="$(basename "$dir")"
  label_map="$LABELS_DIR/$slug.json"
  {
    echo "# Debate transcript"
    echo
    echo "## Topic"
    echo
    cat "$dir/topic.md" 2>/dev/null || echo "(no topic file)"
    for round in 1 2 3; do
      [[ -d "$dir/round-$round" ]] || continue
      echo
      echo "## Round $round"
      for file in "$dir/round-$round"/*.md; do
        [[ -f "$file" ]] || continue
        label="$(basename "$file" .md)"
        short="$(debate_short_for_label "$label_map" "$label" "$slug")"
        echo
        echo "### ${short:-$label}"
        echo
        cat "$file"
      done
    done
  } > "$out"
  echo "$out"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic) TOPIC="${2:?}"; shift 2 ;;
    --topic-file) TOPIC_FILE="${2:?}"; shift 2 ;;
    --slug) SLUG="${2:?}"; shift 2 ;;
    --rounds) ROUNDS="${2:?}"; shift 2 ;;
    --debaters) DEBATERS="${2:?}"; shift 2 ;;
    --judge) JUDGE="${2:?}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    --keep-tabs) KEEP_TABS=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --dir-root) DIR_ROOT="${2:?}"; shift 2 ;;
    --lock-ttl-seconds) LOCK_TTL_SECONDS="${2:?}"; shift 2 ;;
    --labels-dir) LABELS_DIR="${2:?}"; shift 2 ;;
    --manifests-dir) MANIFESTS_DIR="${2:?}"; shift 2 ;;
    --build-transcript) BUILD_ONLY="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$BUILD_ONLY" ]]; then
  build_transcript "$BUILD_ONLY"
  exit 0
fi

if [[ -z "$TOPIC" && -z "$TOPIC_FILE" ]]; then
  usage
  exit 1
fi
if [[ "$ROUNDS" -lt 1 || "$ROUNDS" -gt 3 ]]; then
  echo "--rounds must be 1, 2, or 3" >&2
  exit 1
fi

# --- preflight: drop debaters whose CLI is missing ---
AVAILABLE=""
OLD_IFS="$IFS"
IFS=','
for short in $DEBATERS; do
  [[ -z "${short// }" ]] && continue
  role="$(debate_role_key "$short")"
  # role_launch_cmd exits 1 for a name it doesn't recognize (e.g. a typo in
  # --debaters). Under set -euo pipefail a bare `cli=$(role_launch_cmd ... |
  # awk ...)` would let that non-zero status kill the whole driver right here
  # — silently, before preflight can report anything. `|| cli=""` keeps this
  # a normal "drop from the roster" case instead of a crash.
  cli="$(role_launch_cmd "$role" 2>/dev/null | awk '{print $1}')" || cli=""
  if [[ -z "$cli" ]]; then
    echo "(warn) $short: unrecognized debater — dropping from the roster" >&2
  elif command -v "$cli" >/dev/null 2>&1; then
    AVAILABLE="${AVAILABLE:+$AVAILABLE,}$short"
  else
    echo "(warn) $role: CLI '$cli' not found on PATH — dropping from the roster" >&2
  fi
done
IFS="$OLD_IFS"
DEBATERS="$AVAILABLE"

COUNT="$(printf '%s' "$DEBATERS" | awk -F, '{print NF}')"
if [[ -z "$DEBATERS" || "$COUNT" -lt 3 ]]; then
  echo "Fewer than 3 debater CLIs available (have: ${DEBATERS:-none}). Aborting." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]] && ! orca status --json 2>/dev/null | grep -q '"reachable": true'; then
  echo "Orca runtime not reachable. Open Orca and retry." >&2
  exit 1
fi

# --- debate dir ---
if [[ -n "$TOPIC_FILE" ]]; then
  TOPIC="$(cat "$TOPIC_FILE")"
fi
if [[ -z "$SLUG" ]]; then
  SLUG="$(debate_slugify "$TOPIC")"
fi
# Deferred minor (d): --slug reaches `mkdir -p` raw. debate_slugify's own
# output can never produce '/', '..', or empty, but an explicit --slug is
# user-supplied text with no such guarantee — reject anything that could
# escape $DIR_ROOT before it is ever used to build a path.
case "$SLUG" in
  ""|*/*|*..*)
    echo "Invalid --slug '$SLUG': must be non-empty and must not contain '/' or '..'." >&2
    exit 1
    ;;
esac
DEBATE_DIR="$DIR_ROOT/$SLUG"
# Belt-and-suspenders on top of the sanitization above: assert the computed
# path actually landed under $DIR_ROOT before anything below ever runs
# `rm -rf` against it.
case "$DEBATE_DIR" in
  "$DIR_ROOT"/*) ;;
  *) echo "internal error: computed debate dir '$DEBATE_DIR' is not under dir-root '$DIR_ROOT'" >&2; exit 1 ;;
esac
mkdir -p "$DEBATE_DIR"
printf '%s\n' "$TOPIC" > "$DEBATE_DIR/topic.md"
echo "Debate: $SLUG"
echo "  dir: $DEBATE_DIR"
echo "  debaters: $DEBATERS"

# --- dead-man watchdog (Task 2) + label map (Task 3) ---
# Computed unconditionally (cheap — just paths) so cleanup()/build_transcript
# below can always reference them; only actually created/mutated when
# DRY_RUN=0, since a --dry-run debate creates no terminals and has nothing
# for a watchdog to own.
LOCK_DIR="$ORCH/debate-locks"
LOCK_FILE="$LOCK_DIR/$SLUG.json"
WATCHDOG_PID_FILE="$LOCK_DIR/$SLUG.watchdog.pid"
mkdir -p "$LABELS_DIR"
LABEL_MAP_FILE="$LABELS_DIR/$SLUG.json"

if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$LOCK_DIR"

  # --- Task 3 fix round 1: a global mkdir-based mutex closes the TOCTOU
  # race a plain scan-then-register sequence has. Scanning "$LOCK_DIR/*.json"
  # for another slug's live lock only protects against a driver whose lock
  # ALREADY existed at scan time — but this driver's own lock does not exist
  # until debate_watchdog_start below, so two different-slug drivers started
  # close together could each complete the scan, see nothing, and both
  # proceed into ensure_terminal's shared role terminals (the exact
  # corruption this refusal exists to prevent, merely narrowed to a race
  # window instead of eliminated). debate_startup_mutex_acquire/_release
  # (orca-debate-lib.sh) wrap the ENTIRE scan-then-register sequence below
  # in one critical section: mkdir is atomic on POSIX, so at most one
  # concurrent driver invocation — regardless of slug — can be inside it at
  # a time. A failure to acquire is treated as "refuse to start" (never as
  # "assume clear"), matching the same conservative bias as the refusal
  # itself. Released as soon as this driver's own lock is written (a few
  # lines down), NOT held for the debate's lifetime — see the explicit
  # release below and cleanup()'s own defensive (idempotent) release.
  if ! debate_startup_mutex_acquire "$LOCK_DIR" "$$"; then
    echo "Could not acquire the debate-start coordination lock within ${DEBATE_STARTUP_MUTEX_MAX_WAIT_SECONDS_DEFAULT}s (another driver appears to be starting right now). Refusing to start rather than risk two drivers racing into the same terminals — retry in a moment." >&2
    exit 1
  fi
  # Safety net: if anything between here and the explicit release a few
  # lines down dies unexpectedly (an error under set -e, a signal), this
  # temporary EXIT trap still releases the mutex instead of leaking it
  # forever. Superseded (silently, harmlessly) once `trap cleanup EXIT` is
  # registered further down — cleanup() itself also releases the mutex
  # (idempotent) as a second line of defense.
  trap 'debate_startup_mutex_release "$LOCK_DIR"' EXIT

  # Test seam only: widens the critical section on demand so a test can
  # DETERMINISTICALLY force two concurrent driver invocations to overlap,
  # rather than relying on winning a real, sub-millisecond scheduling race.
  # Never set in real usage.
  if [[ -n "${ORCA_TEST_STARTUP_DELAY_S:-}" ]]; then
    sleep "$ORCA_TEST_STARTUP_DELAY_S"
  fi

  # --- Task 3 extra scope: refuse to start if a DIFFERENT slug's lock is
  # currently live. ensure_terminal (orca-roles-lib.sh) reuses a live role
  # terminal GLOBALLY (one terminal per role key, not per debate), so two
  # concurrent debates under different slugs would dispatch into the SAME
  # four agent sessions — observed live: a second driver's cleanup closed
  # the first driver's tabs mid-round. This uses only the existing
  # lock_is_fresh/lock_pid primitives (see their contract in
  # orca-roles-lib.sh, which prescribes exactly this check) — no new
  # liveness logic. A STALE other-slug lock (no heartbeat within its own
  # ttlSeconds) is presumed abandoned and does not block a new debate; the
  # existing same-slug-fresh-lock warning below is unrelated and unchanged.
  for lf in "$LOCK_DIR"/*.json; do
    [[ -f "$lf" ]] || continue
    other_slug="$(basename "$lf" .json)"
    [[ "$other_slug" == "$SLUG" ]] && continue
    if lock_is_fresh "$lf"; then
      other_pid="$(lock_pid "$lf")"
      alive_note="cannot confirm a pid"
      if [[ -n "$other_pid" ]]; then
        if kill -0 "$other_pid" 2>/dev/null; then
          alive_note="pid $other_pid is alive"
        else
          alive_note="pid $other_pid is NOT running — its watchdog likely has not noticed yet"
        fi
      fi
      echo "Refusing to start: debate '$other_slug' has a live lock ($lf, $alive_note). Starting a second debate now would make ensure_terminal dispatch into the SAME four agent sessions '$other_slug' is using, corrupting both. Wait for '$other_slug' to finish, or — only if you are certain it is actually dead — remove $lf yourself and retry." >&2
      debate_startup_mutex_release "$LOCK_DIR"
      exit 1
    fi
  done

  if [[ -f "$LOCK_FILE" ]] && lock_is_fresh "$LOCK_FILE"; then
    echo "(warn) a fresh debate lock already exists for slug '$SLUG' (pid=$(lock_pid "$LOCK_FILE")) — overwriting it. If that debate is still actually running, its watchdog will notice the pid no longer matches this run and stand down without closing anything (see orca-sweep-orphans.sh), but two drivers now believe they own the same tabs. Consider --slug to pick a different slug if that was not intended." >&2
  fi

  # Deferred finding I1: every real run of a slug is treated as fresh. There
  # is no partial-resume feature (the round loop below always restarts at
  # round 1), so a prior run's leftover round output / transcript / manifest
  # must never be mistaken for THIS run's — otherwise a stale file can pass
  # the collection step's `-s` usability check even though nothing this run
  # actually produced it. --dry-run never reaches this branch, so a preview
  # never destroys real data.
  if [[ -d "$DEBATE_DIR/round-1" || -d "$DEBATE_DIR/round-2" || -d "$DEBATE_DIR/round-3" || -f "$DEBATE_DIR/transcript.md" ]]; then
    echo "(info) clearing previous round output for slug '$SLUG' — every real run starts fresh" >&2
  fi
  rm -rf "${DEBATE_DIR:?}"/round-* 2>/dev/null || true
  rm -f "$DEBATE_DIR/transcript.md"
  rm -rf "${MANIFESTS_DIR:?}/$SLUG" 2>/dev/null || true

  # Only the driver ever creates/rebuilds the label map (Task 3) — see
  # debate_label_map_ensure's own header comment for the full contract.
  # Safe to rebuild on a roster mismatch specifically because the wipe just
  # above already guarantees no old-mapping output can still be lying around.
  debate_label_map_ensure "$LABEL_MAP_FILE" "$SLUG" "$DEBATERS" >/dev/null

  WATCHDOG_PID="$(debate_watchdog_start "$HERE" "$LOCK_FILE" "$SLUG" "$$" "$LOCK_DIR" "$LOCK_TTL_SECONDS")"
  printf '%s\n' "$WATCHDOG_PID" > "$WATCHDOG_PID_FILE"
  export ORCA_ROLE_LOCK_FILE="$LOCK_FILE"
  echo "  watchdog: pid=$WATCHDOG_PID ttl=${LOCK_TTL_SECONDS}s lock=$LOCK_FILE"

  # Our own lock is now on disk (lock_write, inside debate_watchdog_start)
  # and therefore visible to any OTHER driver's scan — release the mutex
  # immediately so it is held only for this brief registration window, never
  # for this debate's entire lifetime.
  debate_startup_mutex_release "$LOCK_DIR"
else
  # --dry-run must NEVER write the real label map: a partial-roster preview
  # (e.g. --debaters claude,grok --dry-run) would otherwise leave a 2-seat
  # roster recorded at the real path, and a later real run with the full
  # roster would needlessly see that as a "roster changed" rebuild — or, in
  # the bug this replaces, the old code reused that stale 2-seat map
  # outright for a real run. Use a throwaway path instead (cleaned up in
  # cleanup() below).
  EPHEMERAL_LABEL_MAP="$(mktemp "${TMPDIR:-/tmp}/orca-debate-labels.XXXXXX")"
  rm -f "$EPHEMERAL_LABEL_MAP"   # debate_label_map_ensure creates it fresh
  LABEL_MAP_FILE="$EPHEMERAL_LABEL_MAP"
  debate_label_map_ensure "$LABEL_MAP_FILE" "$SLUG" "$DEBATERS" >/dev/null
fi

# --- close debater tabs on any exit ---
cleanup() {
  # Stop the watchdog and remove the lock FIRST, unconditionally — even
  # under --keep-tabs. A driver reaching cleanup() is exiting deliberately;
  # the dead-man's-switch concern (an owner that stops proving it is alive)
  # is over regardless of whether tabs are being kept open on purpose for
  # debugging. Doing this before the KEEP_TABS/DRY_RUN early return below,
  # and before this function's own tab-closing loop, means the watchdog can
  # never race this driver's own close attempts. debate_watchdog_stop is a
  # guarded no-op when nothing was ever started (--dry-run).
  debate_watchdog_stop "$WATCHDOG_PID_FILE" "$LOCK_FILE"

  # Defensive, idempotent second release of the startup mutex (see the
  # explicit release right after debate_watchdog_start, and the temporary
  # EXIT trap registered right after acquiring it) — a harmless no-op in the
  # normal case where it was already released; a real backstop if some path
  # through the DRY_RUN=0 block above ever reaches here without having done
  # so itself.
  debate_startup_mutex_release "$LOCK_DIR"

  # Throwaway --dry-run label map (never the real $LABELS_DIR/<slug>.json —
  # see the DRY_RUN branch above): tidy it up regardless of KEEP_TABS/DRY_RUN,
  # since it was never a debater-facing artifact and has nothing to keep.
  if [[ -n "$EPHEMERAL_LABEL_MAP" ]]; then
    rm -f "$EPHEMERAL_LABEL_MAP"
  fi

  if [[ "$KEEP_TABS" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  local old="$IFS" short
  local roster=()
  IFS=','
  for short in $DEBATERS; do
    roster+=("$short")
  done
  IFS="$old"
  for short in "${roster[@]}"; do
    # ensure_terminal reuses a live role terminal globally, so a debater's
    # handle here can be the exact same underlying terminal a DIFFERENT,
    # still-running debate is depending on right now — this driver ending
    # normally is not evidence that handle is safe to close. Same check,
    # same reasoning, as the watchdog's own close-phase guard in
    # orca-sweep-orphans.sh (our own lock was already removed by
    # debate_watchdog_stop above, so this only ever matches an OTHER
    # debate's lock).
    local role_key handle
    role_key="$(debate_role_key "$short")"
    handle="$(handles_get "$HANDLES_FILE" "$role_key" 2>/dev/null || true)"
    if [[ -n "$handle" ]] && lock_handle_claimed_elsewhere "$LOCK_DIR" "$handle" "$LOCK_FILE"; then
      echo "cleanup: leaving $short ($handle) alone — claimed by a different, still-active debate" >&2
      continue
    fi
    # Outcomes are observable (not silenced to /dev/null) — a driver that
    # cannot see why a close failed cannot diagnose exactly the class of
    # failure this task exists to fix.
    local close_out close_rc=0
    close_out="$("$HERE/orca-close-role.sh" "$role_key" 2>&1)" || close_rc=$?
    if [[ "$close_rc" -eq 0 ]]; then
      echo "cleanup: closed $short — $close_out" >&2
    else
      echo "cleanup: close FAILED for $short (rc=$close_rc) — $close_out" >&2
    fi
  done
}
# A single `trap cleanup EXIT INT TERM` looks right but is not: cleanup()
# never calls exit, and in bash, a trap on a terminating signal (INT/TERM)
# whose handler does not itself call exit does NOT stop the script — control
# resumes after the interrupted command. Concretely: the round loop below
# does `if ! orca-debate-round.sh ...; then ... break; fi`, which treats ANY
# non-zero exit from the round script — including 130 from a SIGINT-killed
# round — the same as a quorum failure: it prints "did not meet quorum" and
# falls through to building a transcript (and possibly dispatching --judge)
# from a debate the user just interrupted, instead of actually stopping.
# Binding EXIT alone to cleanup and giving INT/TERM their own trap that calls
# exit fixes this: exit inside a signal trap still fires the EXIT trap in
# bash (verified on bash 3.2.57, this repo's floor), so cleanup still runs
# exactly once, but the script actually stops instead of completing the
# debate anyway.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

phase_for_round() {
  case "$1" in
    1) echo propose ;;
    2) echo critique ;;
    3) echo converge ;;
  esac
}

for round in $(seq 1 "$ROUNDS"); do
  phase="$(phase_for_round "$round")"
  if [[ -n "$TIMEOUT_MS" ]]; then
    t="$TIMEOUT_MS"
  elif [[ "$round" -eq 1 ]]; then
    t="$R1_TIMEOUT_MS"
  else
    t="$RN_TIMEOUT_MS"
  fi
  echo
  echo "=== ROUND $round: $phase (timeout ${t}ms) ==="
  ARGS=(--dir "$DEBATE_DIR" --round "$round" --phase "$phase" --debaters "$DEBATERS" \
        --timeout-ms "$t" --label-map "$LABEL_MAP_FILE" \
        --manifest "$MANIFESTS_DIR/$SLUG/round-$round.json")
  [[ "$DRY_RUN" -eq 1 ]] && ARGS+=(--dry-run)
  # Deferred minor (a): orca-debate-round.sh's exit codes are NOT
  # interchangeable — 2 means quorum genuinely failed (fewer than 3 usable
  # outputs), but 1 means a usage/internal error in the round script itself
  # (e.g. a missing --label-map), and anything else (notably 130/143 if the
  # round script is itself signaled) is neither. Treating every non-zero
  # exit as "did not meet quorum" would misreport a usage bug as a debate
  # that genuinely failed to converge — exactly backwards for live
  # debugging. `rc=0; cmd || rc=$?` (rather than a bare `if ! cmd`) is what
  # makes the real code observable here under `set -e`.
  rc=0
  "$HERE/orca-debate-round.sh" "${ARGS[@]}" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    :
  elif [[ "$rc" -eq 2 ]]; then
    echo "Round $round did not meet quorum (need 3 usable outputs) — stopping." >&2
    break
  else
    echo "Round $round exited with code $rc — a usage error, crash, or interruption in the round script itself, NOT a quorum failure — stopping." >&2
    break
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

TRANSCRIPT="$(build_transcript "$DEBATE_DIR")"
echo
echo "Transcript: $TRANSCRIPT"

DECISION_DIR="$ROOT/docs/ideas"
DECISION="$DECISION_DIR/$(date -u +%Y-%m-%d)-$SLUG.md"

if [[ -n "$JUDGE" ]]; then
  mkdir -p "$DECISION_DIR"
  "$HERE/orca-dispatch-role.sh" "$JUDGE" --spec "You are the judge of a finished four-model idea debate.

Read the full transcript: $TRANSCRIPT

Write the decision document to: $DECISION

Required sections, in this order:
## Decision
The chosen niche, its kill condition, and the first validation experiment
(with a numeric success threshold).
## Runner-up
The strongest rejected candidate and exactly why it lost.
## Dissent
Positions from round 3 that this decision does NOT resolve. Attribute each to the
round-3 file it came from. Never delete a dissent to make the decision look cleaner.

Judge on evidence. Claims tagged [출처: 미검증] carry less weight than sourced ones.
Do not add ideas of your own that no participant proposed."
  echo "Judge dispatched → $DECISION"
else
  echo
  echo "Next: read $TRANSCRIPT and write the decision document to"
  echo "  $DECISION"
  echo "with sections: ## Decision / ## Runner-up / ## Dissent"
fi
