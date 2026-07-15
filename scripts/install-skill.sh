#!/usr/bin/env bash
# Install or update the global orca-role-orchestration skill (clone-or-pull + symlinks).
# Same command re-runs as update — superpowers-style free reinstall.
#
# Usage:
#   install-skill.sh [--repo URL] [--canonical PATH]
set -euo pipefail

REPO_URL="https://github.com/zeromountain/orca-role-orchestration.git"
CANON="${HOME}/.agents/skills/orca-role-orchestration"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_URL="${2:?}"; shift 2 ;;
    --canonical) CANON="${2:?}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--repo URL] [--canonical PATH]"
      exit 0
      ;;
    *)
      echo "Unknown: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$(dirname "$CANON")"

if [[ -d "$CANON/.git" ]]; then
  echo "Updating $CANON (git pull --ff-only)…"
  git -C "$CANON" pull --ff-only
elif [[ -d "$CANON" ]]; then
  echo "ERROR: $CANON exists but is not a git checkout. Move it aside or pass --canonical." >&2
  exit 1
else
  echo "Cloning $REPO_URL → $CANON"
  git clone "$REPO_URL" "$CANON"
fi

VERSION="unknown"
if git -C "$CANON" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VERSION="$(git -C "$CANON" describe --tags --always --dirty 2>/dev/null || echo unknown)"
fi

linked=()
for d in "${HOME}/.claude/skills" "${HOME}/.codex/skills" "${HOME}/.grok/skills"; do
  if [[ -d "$d" ]]; then
    ln -sfn "$CANON" "$d/orca-role-orchestration"
    linked+=("$d/orca-role-orchestration")
  fi
done

echo "orca-role-orchestration ${VERSION} → ${CANON}"
if [[ ${#linked[@]} -gt 0 ]]; then
  echo "  linked: ${linked[*]}"
else
  echo "  linked: (none — no ~/.claude|codex|grok/skills dirs present)"
fi
echo "Project scaffold (install/update):"
echo "  ${CANON}/scripts/install-to-project.sh --project-root \"\$(pwd)\""
