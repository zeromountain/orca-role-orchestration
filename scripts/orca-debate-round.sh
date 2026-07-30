#!/usr/bin/env bash
# One round of a multi-model idea debate.
#
# Fans out one dispatch per debater, waits for every dispatch to reach a terminal
# state by polling dispatch-show (never consumes the orchestration inbox), collects
# each debater's output file from disk, lints it, and prepares the next round's
# anonymized copies.
#
# Usage:
#   orca-debate-round.sh --dir <debate-dir> --round <N> --phase propose|critique|converge
#                        [--debaters claude,codex,grok,gemini] [--timeout-ms N] [--dry-run]
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
                       [--debaters claude,codex,grok,gemini] [--timeout-ms N] [--dry-run]

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
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$DIR" || -z "$ROUND" || -z "$PHASE" ]]; then
  usage
  exit 1
fi
case "$PHASE" in
  propose|critique|converge) ;;
  *) echo "phase must be propose|critique|converge" >&2; exit 1 ;;
esac

TOPIC_FILE="$DIR/topic.md"
ROUND_DIR="$DIR/round-$ROUND"
NEXT_DIR="$DIR/round-$((ROUND + 1))"
MANIFEST="$ROUND_DIR/manifest.json"
MAP_FILE="$DIR/round-2/label-map.json"
mkdir -p "$ROUND_DIR"

# Label map is created up front so every round can address participants by label.
mkdir -p "$DIR/round-2"
debate_label_map_create "$MAP_FILE" "$DEBATERS" >/dev/null

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
  out="$ROUND_DIR/$short.md"
  own="$(debate_label_of "$MAP_FILE" "$short")"
  spec="$(debate_spec "$PHASE" "$short" "$DIR" "$ROUND" "$out" "$own" "$TOPIC_FILE")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '===== %s =====\n%s\n\n' "$role" "$spec"
    TASK_IDS+=("dry")
    STATUSES+=("dry")
    continue
  fi

  # `|| true` keeps a non-zero dispatcher exit from aborting the whole round
  # under `set -euo pipefail`: without it, pipefail would make this bare
  # assignment's own exit status non-zero (the same bare-assignment-vs-`local`
  # distinction documented in debate_lint), and `set -e` would kill the script
  # mid-fanout — orphaning already-dispatched debaters and losing the manifest
  # entirely instead of forfeiting just this one debater below.
  tid="$("$DISPATCH_BIN" "$role" --persist --spec "$spec" | awk -F= '/^task_id=/{print $2; exit}' || true)"
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
rm -f "$MANIFEST"
usable=0
for i in "${!NAMES[@]}"; do
  short="${NAMES[$i]}"
  file="$ROUND_DIR/$short.md"
  flags=""
  if [[ "${STATUSES[$i]}" == "completed" && -s "$file" ]]; then
    usable=$((usable + 1))
    flags="ok"
    if ! debate_lint "$file" "$PHASE" 2>/dev/null; then
      flags="lint-fail"
      echo "  (warn) $short: output missing required headings — kept, flagged" >&2
    fi
  else
    flags="forfeit"
    echo "  (warn) $short: forfeit (status=${STATUSES[$i]})" >&2
  fi
  debate_manifest_append "$MANIFEST" "$short" "${TASK_IDS[$i]}" "${STATUSES[$i]}" "$flags"
done

echo "Round $ROUND: $usable/${#NAMES[@]} usable" >&2
if [[ "$usable" -lt "$QUORUM" ]]; then
  echo "Quorum failed (need $QUORUM). Stopping the debate." >&2
  exit 2
fi

# --- prepare the next round's anonymized inputs ---
case "$PHASE" in
  propose)  debate_anonymize "$MAP_FILE" "$ROUND_DIR" "$NEXT_DIR" proposal >/dev/null ;;
  critique) debate_anonymize "$MAP_FILE" "$ROUND_DIR" "$NEXT_DIR" critique >/dev/null ;;
esac

exit 0
