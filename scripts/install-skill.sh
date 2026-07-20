#!/usr/bin/env bash
# Install or update the global orca-role-orchestration skill (clone-or-pull + symlinks).
# Same command re-runs as update — superpowers-style free reinstall.
#
# Usage:
#   install-skill.sh [--repo URL] [--canonical PATH]
set -euo pipefail

REPO_URL="https://github.com/zeromountain/orca-role-orchestration.git"
CANON="${HOME}/.agents/skills/orca-role-orchestration"

UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_URL="${2:?}"; shift 2 ;;
    --canonical) CANON="${2:?}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--repo URL] [--canonical PATH] [--uninstall]"
      echo "  --uninstall  remove every symlink pointing into the canonical checkout"
      echo "               (the checkout itself is kept — delete it manually)"
      exit 0
      ;;
    *)
      echo "Unknown: $1" >&2
      exit 1
      ;;
  esac
done

CODEX_PROMPTS="${CODEX_HOME:-${HOME}/.codex}/prompts"

# Remove only symlinks we own: they must resolve into $CANON.
prune_ours() {
  local removed=0 target
  for target in "$@"; do
    [[ -L "$target" ]] || continue
    case "$(readlink "$target")" in
      "$CANON"|"$CANON"/*) rm -f "$target"; removed=$((removed + 1)) ;;
    esac
  done
  echo "$removed"
}

if [[ $UNINSTALL -eq 1 ]]; then
  n=$(prune_ours \
    "${HOME}/.claude/skills/orca-role-orchestration" \
    "${HOME}/.codex/skills/orca-role-orchestration" \
    "${HOME}/.grok/skills/orca-role-orchestration" \
    "$CODEX_PROMPTS"/orca-*.md)
  echo "orca-role-orchestration uninstalled: ${n} symlink(s) removed"
  echo "  checkout kept: ${CANON}  (rm -rf it to remove completely)"
  exit 0
fi

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

# Codex slash commands live in $CODEX_HOME/prompts (plugin manifests carry no prompts field).
prompts_linked=0
if [[ -d "${CODEX_HOME:-${HOME}/.codex}" ]]; then
  mkdir -p "$CODEX_PROMPTS"
  # Drop our stale links first, so renamed/deleted prompts don't linger as ghost commands.
  prune_ours "$CODEX_PROMPTS"/orca-*.md >/dev/null
  for p in "$CANON"/prompts/*.md; do
    [[ -e "$p" ]] || continue
    ln -sfn "$p" "$CODEX_PROMPTS/$(basename "$p")"
    prompts_linked=$((prompts_linked + 1))
  done
fi

echo "orca-role-orchestration ${VERSION} → ${CANON}"
if [[ ${#linked[@]} -gt 0 ]]; then
  echo "  linked: ${linked[*]}"
else
  echo "  linked: (none — no ~/.claude|codex|grok/skills dirs present)"
fi
if [[ $prompts_linked -gt 0 ]]; then
  echo "  codex prompts: ${prompts_linked} → ${CODEX_PROMPTS} (/orca-install, /orca-dispatch, …)"
fi
echo "Project scaffold (install/update):"
echo "  ${CANON}/scripts/install-to-project.sh --project-root \"\$(pwd)\""
