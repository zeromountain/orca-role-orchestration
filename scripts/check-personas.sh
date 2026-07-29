#!/usr/bin/env bash
# Lint role persona files: required skeleton sections + a non-empty STANCE marker.
# Test harness for the persona system. NOT installed into projects.
# Usage: scripts/check-personas.sh [personas-dir]
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/templates/personas}"
# Every persona: H1 + non-empty STANCE (the parts the scripts consume).
ALL_ROLES=(architect executor thrifty ui reviewer fallback coordinator
           debater_claude debater_codex debater_grok debater_gemini)
# Nine-section skeleton. ui/reviewer use a different, later structure by design.
SKELETON_ROLES=(architect executor thrifty fallback coordinator
                debater_claude debater_codex debater_grok debater_gemini)

SECTIONS=(
  '**Who you are.**'
  '**Mission.**'
  '**Play to these strengths.**'
  '**Guard against these failure modes.**'
  '**How you decide'
  '**Output contract.**'
  '**Collaboration protocol.**'
  '**Definition of done.**'
  '**Never.**'
)

is_skeleton_role() {
  local role="$1" r
  for r in "${SKELETON_ROLES[@]}"; do
    [[ "$r" == "$role" ]] && return 0
  done
  return 1
}

fail=0
for role in "${ALL_ROLES[@]}"; do
  f="$DIR/$role.md"
  if [[ ! -f "$f" ]]; then
    echo "MISSING: $f"; fail=1; continue
  fi
  if ! grep -Eq '^# ' "$f"; then
    echo "NO H1: $f"; fail=1
  fi
  stance="$(grep -m1 'STANCE:' "$f" | sed -E 's/.*STANCE:[[:space:]]*//; s/[[:space:]]*-->.*//')"
  if [[ -z "${stance// }" ]]; then
    echo "EMPTY STANCE: $f"; fail=1
  fi
  if is_skeleton_role "$role"; then
    for s in "${SECTIONS[@]}"; do
      if ! grep -Fq "$s" "$f"; then
        echo "MISSING SECTION [$s]: $f"; fail=1
      fi
    done
  fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "OK: all persona files valid ($DIR)"
fi
exit "$fail"
