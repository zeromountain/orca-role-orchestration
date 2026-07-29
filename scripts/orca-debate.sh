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

# Per-round defaults: R1 carries the research obligation and gets longer.
R1_TIMEOUT_MS=1800000
RN_TIMEOUT_MS=900000

usage() {
  cat <<'EOF'
Usage:
  orca-debate.sh --topic "…" | --topic-file <file>
                 [--slug <s>] [--rounds 1|2|3] [--debaters claude,codex,grok,gemini]
                 [--judge <role>] [--timeout-ms N] [--keep-tabs] [--dry-run]
                 [--dir-root <path>]
  orca-debate.sh --build-transcript <debate-dir>

  --judge <role>   Dispatch this role to write the decision document
                   (default: leave it to the coordinator).
  --keep-tabs      Do not close debater tabs on exit (debugging).
  --dry-run        Print every round's specs; create no terminals.
EOF
}

build_transcript() {
  # $1=debate dir
  local dir="$1" out="$1/transcript.md" round file short
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
        short="$(basename "$file" .md)"
        case "$short" in
          proposal-*|critique-*) continue ;;
        esac
        echo
        echo "### $short"
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
  cli="$(role_launch_cmd "$role" 2>/dev/null | awk '{print $1}')"
  if command -v "$cli" >/dev/null 2>&1; then
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
DEBATE_DIR="$DIR_ROOT/$SLUG"
mkdir -p "$DEBATE_DIR"
printf '%s\n' "$TOPIC" > "$DEBATE_DIR/topic.md"
echo "Debate: $SLUG"
echo "  dir: $DEBATE_DIR"
echo "  debaters: $DEBATERS"

# --- close debater tabs on any exit ---
cleanup() {
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
    "$HERE/orca-close-role.sh" "$(debate_role_key "$short")" >/dev/null 2>&1 || true
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
  ARGS=(--dir "$DEBATE_DIR" --round "$round" --phase "$phase" --debaters "$DEBATERS" --timeout-ms "$t")
  [[ "$DRY_RUN" -eq 1 ]] && ARGS+=(--dry-run)
  if ! "$HERE/orca-debate-round.sh" "${ARGS[@]}"; then
    echo "Round $round did not meet quorum — stopping." >&2
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
