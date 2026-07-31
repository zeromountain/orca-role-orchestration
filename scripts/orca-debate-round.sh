#!/usr/bin/env bash
# One round of a multi-model idea debate.
#
# Fans out one dispatch per debater, waits for every dispatch to reach a terminal
# state by polling dispatch-show (never consumes the orchestration inbox), and
# collects each debater's output file from disk (already written under its
# label name — see --label-map below) and lints it.
#
# Usage:
#   orca-debate-round.sh --dir <debate-dir> --round <N> --phase propose|critique|converge
#                        --label-map <path> [--manifest <path>]
#                        [--debaters claude,codex,grok,gemini] [--timeout-ms N] [--dry-run]
#
# --label-map and --manifest are external to <debate-dir> by design (Task 3):
# the label map (roster + shuffled label assignment) and the per-round
# manifest (real debater names + task ids + statuses) are driver-only state —
# nothing inside <debate-dir> may ever reveal a debater's identity. This
# script never creates or owns either file; --label-map must already exist
# (for a real, non-dry-run round — orca-debate.sh creates/rebuilds it before
# calling here) and --manifest, if given, is written to directly.
#
# Exit: 0 quorum met (3+ usable outputs) · 2 quorum failed · 1 usage error
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
# shellcheck source=orca-debate-lib.sh
source "$HERE/orca-debate-lib.sh"
HANDLES_FILE="$ORCH/handles.json"

DIR=""
ROUND=""
PHASE=""
DEBATERS="$DEBATERS_DEFAULT"
TIMEOUT_MS=900000
POLL_S=5
DRY_RUN=0
QUORUM=3
LABEL_MAP=""
MANIFEST=""

# Test seams: allow the dispatcher and the status source to be stubbed. These
# are ORCA_TEST_-prefixed (not ORCA_DEBATE_-prefixed) because they are live env
# vars that override real dispatch behavior — a name that reads as "debate
# config" invites setting it in a real environment by accident; ORCA_TEST_
# makes clear this seam exists for tests only.
DISPATCH_BIN="${ORCA_TEST_DISPATCH:-$HERE/orca-dispatch-role.sh}"
STATUS_STUB="${ORCA_TEST_STATUS_STUB:-}"

usage() {
  cat <<'EOF'
Usage:
  orca-debate-round.sh --dir <debate-dir> --round <N> --phase propose|critique|converge
                       --label-map <path> [--manifest <path>]
                       [--debaters claude,codex,grok,gemini] [--timeout-ms N] [--dry-run]

  --label-map <path>  Required. Path to the label map (roster + shuffled
                      label assignment) that orca-debate.sh already created
                      for this slug. Must exist for a real (non-dry-run)
                      round; tolerated missing only under --dry-run (where
                      each debater's own label falls back to "?" in the
                      printed preview, since nothing is actually dispatched).
  --manifest <path>   Optional. Where to record this round's per-debater
                      task id / status / lint flags (by real short name —
                      driver-only state, outside <debate-dir>). Omit to skip.
  --dry-run   Print the spec each debater would receive; dispatch nothing.
Exit codes: 0 quorum met · 2 quorum failed (fewer than 3 usable outputs)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="${2:?}"; shift 2 ;;
    --round) ROUND="${2:?}"; shift 2 ;;
    --phase) PHASE="${2:?}"; shift 2 ;;
    --debaters) DEBATERS="${2:?}"; shift 2 ;;
    --timeout-ms) TIMEOUT_MS="${2:?}"; shift 2 ;;
    --poll-s) POLL_S="${2:?}"; shift 2 ;;
    --label-map) LABEL_MAP="${2:?}"; shift 2 ;;
    --manifest) MANIFEST="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$DIR" || -z "$ROUND" || -z "$PHASE" || -z "$LABEL_MAP" ]]; then
  usage
  exit 1
fi
case "$PHASE" in
  propose|critique|converge) ;;
  *) echo "phase must be propose|critique|converge" >&2; exit 1 ;;
esac
if [[ "$DRY_RUN" -eq 0 && ! -f "$LABEL_MAP" ]]; then
  echo "label map not found: $LABEL_MAP — the driver (orca-debate.sh) must create this before dispatching any real round; this script never creates its own" >&2
  exit 1
fi

TOPIC_FILE="$DIR/topic.md"
ROUND_DIR="$DIR/round-$ROUND"
MAP_FILE="$LABEL_MAP"
mkdir -p "$ROUND_DIR"

NAMES=()
OLD_IFS="$IFS"
IFS=','
for n in $DEBATERS; do
  if [[ -n "${n// }" ]]; then
    NAMES+=("$n")
  fi
done
IFS="$OLD_IFS"

TASK_IDS=()
STATUSES=()

echo "Round $ROUND ($PHASE): ${#NAMES[@]} debaters — ${NAMES[*]}" >&2

for i in "${!NAMES[@]}"; do
  short="${NAMES[$i]}"
  role="$(debate_role_key "$short")"
  own="$(debate_label_of "$MAP_FILE" "$short")"
  if [[ -z "$own" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      # No real driver-created map behind this preview (e.g. this script
      # invoked directly, without going through orca-debate.sh) — "own" is
      # only ever interpolated into preview text here, never used to decide
      # anything, so a placeholder keeps the preview complete instead of
      # silently dropping this debater from it.
      own="?"
    else
      echo "  (warn) $short: no label assigned in $MAP_FILE — forfeiting (driver/label-map bug?)" >&2
      TASK_IDS+=("none")
      STATUSES+=("failed")
      continue
    fi
  fi
  out="$ROUND_DIR/$own.md"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    # A stale file left at this exact path by a PREVIOUS run must never be
    # mistaken for this run's output: if this dispatch reports "completed"
    # without actually writing anything, the collection step below gates
    # usability on `-s "$file"` (non-empty) — without this removal, that
    # check could see old content and silently count a forfeit as usable
    # (deferred finding I1). orca-debate.sh already wipes round-*/ for this
    # slug before round 1 of a real run, so this is defense in depth for any
    # direct/partial invocation of this script that skips that wipe.
    rm -f "$out"
  fi
  spec="$(debate_spec "$PHASE" "$short" "$DIR" "$ROUND" "$out" "$own" "$TOPIC_FILE")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '===== %s =====\n%s\n\n' "$role" "$spec"
    TASK_IDS+=("dry")
    STATUSES+=("dry")
    continue
  fi

  # Fix round (whole-branch review, item 5): the old code piped the
  # dispatcher directly into `awk '{...; exit}'` — awk's own `exit` on the
  # FIRST match closes its end of the pipe, and orca-dispatch-role.sh prints
  # "task_id=..." (line ~192) well BEFORE its slower --inject call (line
  # ~201), so the dispatcher's next stdout write after that point gets
  # SIGPIPE, silently, under the trailing `|| true` below — a script dying
  # on a signal, exactly the class of bug this branch spent two prior plans
  # eliminating elsewhere. Worse than a cosmetic loss: the dispatcher can be
  # killed BEFORE it ever injects the seat's prompt, leaving that seat's
  # task created but never dispatched. Fixed by capturing the dispatcher's
  # FULL stdout into a variable first — no process is ever attached to the
  # other end of a live pipe from the dispatcher once this runs, so it can
  # never be SIGPIPE'd — then parsing task_id out of the captured string via
  # a here-string (no new pipe either). `|| true` on the capture (not
  # `|| dispatch_out=""`) preserves whatever the dispatcher DID print even
  # on a non-zero exit — bash still assigns the captured output before the
  # `||` is evaluated, and a dispatcher that created the task before failing
  # later must not have that output silently discarded.
  dispatch_out="$("$DISPATCH_BIN" "$role" --persist --spec "$spec")" || true
  tid="$(awk -F= '/^task_id=/{print $2; exit}' <<<"$dispatch_out")" || tid=""
  if [[ -z "$tid" ]]; then
    echo "  (warn) $role produced no task id" >&2
    tid="none"
  fi
  echo "  $role → $tid" >&2
  TASK_IDS+=("$tid")
  STATUSES+=("pending")
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

# --- poll every dispatch to a terminal state (no inbox consumption) ---
START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
while true; do
  all_done=1
  for i in "${!TASK_IDS[@]}"; do
    [[ "${STATUSES[$i]}" != "pending" ]] && continue
    if [[ "${TASK_IDS[$i]}" == "none" ]]; then
      STATUSES[$i]="failed"
      continue
    fi
    if [[ -n "$STATUS_STUB" ]]; then
      st="$STATUS_STUB"
    else
      st="$(dispatch_status "${TASK_IDS[$i]}")"
    fi
    case "$st" in
      completed|failed) STATUSES[$i]="$st" ;;
      *) all_done=0 ;;
    esac
  done
  if [[ "$all_done" -eq 1 ]]; then
    break
  fi
  NOW_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
  if [[ $((NOW_MS - START_MS)) -ge "$TIMEOUT_MS" ]]; then
    for i in "${!STATUSES[@]}"; do
      [[ "${STATUSES[$i]}" == "pending" ]] && STATUSES[$i]="timeout"
    done
    echo "  (warn) round $ROUND timed out after ${TIMEOUT_MS}ms" >&2
    break
  fi
  sleep "$POLL_S"
done

# --- collect, lint, quorum ---
# $MANIFEST is optional and, when given, lives OUTSIDE <debate-dir> (the
# driver computes it under $ORCH/debate-manifests/<slug>/round-N.json) —
# it records real short names, so it must never sit anywhere a debater's
# glob/read could reach it. rm -f guards against a re-invocation of this
# exact round leaving duplicate rows in an already-existing manifest file.
if [[ -n "$MANIFEST" ]]; then
  mkdir -p "$(dirname "$MANIFEST")" 2>/dev/null || true
  rm -f "$MANIFEST"
fi
usable=0
for i in "${!NAMES[@]}"; do
  short="${NAMES[$i]}"
  own="$(debate_label_of "$MAP_FILE" "$short")"
  file="$ROUND_DIR/$own.md"
  flags=""
  if [[ -n "$own" && "${STATUSES[$i]}" == "completed" && -s "$file" ]]; then
    usable=$((usable + 1))
    flags="ok"
    lint_out=""
    if ! lint_out="$(debate_lint "$file" "$PHASE" 2>&1)"; then
      flags="lint-fail"
      echo "  (warn) $short: output missing required headings — kept, flagged" >&2
      printf '%s\n' "$lint_out" | sed 's/^/    /' >&2
    fi
  else
    flags="forfeit"
    echo "  (warn) $short: forfeit (status=${STATUSES[$i]})" >&2
  fi
  if [[ -n "$MANIFEST" ]]; then
    debate_manifest_append "$MANIFEST" "$short" "${TASK_IDS[$i]}" "${STATUSES[$i]}" "$flags"
  fi
done

echo "Round $ROUND: $usable/${#NAMES[@]} usable" >&2
if [[ "$usable" -lt "$QUORUM" ]]; then
  echo "Quorum failed (need $QUORUM). Stopping the debate." >&2
  exit 2
fi

# Nothing to prepare for the next round: output was already written directly
# under its label name above (round-$ROUND/$own.md) — there is no named
# original to copy or redact. The next round's spec (debate_spec, in
# orca-debate-lib.sh) points straight at this round's directory.

exit 0
