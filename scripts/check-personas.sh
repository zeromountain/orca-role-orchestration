#!/usr/bin/env bash
# Lint role persona files: required skeleton sections + a non-empty STANCE marker.
# Test harness for the persona system. NOT installed into projects.
# Usage: scripts/check-personas.sh [personas-dir]
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/templates/personas}"
ROLES=(architect executor thrifty fallback coordinator)
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

fail=0
for role in "${ROLES[@]}"; do
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
  for s in "${SECTIONS[@]}"; do
    if ! grep -Fq "$s" "$f"; then
      echo "MISSING SECTION [$s]: $f"; fail=1
    fi
  done
done

if [[ "$fail" -eq 0 ]]; then
  echo "OK: all persona files valid ($DIR)"
fi
exit "$fail"
