#!/usr/bin/env bash
# Install Orca role-orchestration scaffold into a project root.
# Usage:
#   install-to-project.sh [--project-root PATH] [--project-name NAME] [--force]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SKILL_DIR/templates"
SCRIPTS_SRC="$SKILL_DIR/scripts"
ROOT=""
PROJECT_NAME=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) ROOT="${2:?}"; shift 2 ;;
    --project-name) PROJECT_NAME="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--project-root PATH] [--project-name NAME] [--force]"
      exit 0
      ;;
    *)
      echo "Unknown: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  ROOT="$(pwd)"
fi
ROOT="$(cd "$ROOT" && pwd)"

if [[ -z "$PROJECT_NAME" ]]; then
  if [[ -f "$ROOT/package.json" ]]; then
    PROJECT_NAME="$(python3 - "$ROOT/package.json" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1]) as stream:
    print(json.load(stream).get("name") or "")
PY
)"
  fi
  if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(basename "$ROOT")"
  fi
fi

ORCH="$ROOT/.orca/orchestration"
SCRIPTS_DST="$ROOT/scripts"

echo "Installing orca-role-orchestration → $ROOT (project=$PROJECT_NAME)"

mkdir -p "$ORCH" "$SCRIPTS_DST"

install_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "$dst" && "$FORCE" -ne 1 ]]; then
    echo "  skip existing: $dst (use --force to overwrite)"
    return
  fi
  if [[ "$src" == *.yaml ]] || [[ "$src" == *.md ]]; then
    python3 - "$src" "$dst" "$PROJECT_NAME" <<'PY'
import pathlib
import sys

source, destination, project_name = sys.argv[1:4]
text = pathlib.Path(source).read_text()
pathlib.Path(destination).write_text(text.replace("{{PROJECT_NAME}}", project_name))
PY
  else
    cp "$src" "$dst"
  fi
  echo "  wrote $dst"
}

install_file "$TPL/roles.yaml" "$ORCH/roles.yaml"
install_file "$TPL/PLAYBOOK.md" "$ORCH/PLAYBOOK.md"
install_file "$TPL/SCRIPTS.md" "$ORCH/SCRIPTS.md"
install_file "$TPL/handles.example.json" "$ORCH/handles.example.json"

mkdir -p "$ORCH/personas"
for p in "$TPL"/personas/*.md; do
  install_file "$p" "$ORCH/personas/$(basename "$p")"
done

for s in orca-bootstrap-roles.sh orca-dispatch-role.sh orca-fallback-on-limit.sh; do
  install_file "$SCRIPTS_SRC/$s" "$SCRIPTS_DST/$s"
  chmod +x "$SCRIPTS_DST/$s"
done

# gitignore handles.json
GI="$ROOT/.gitignore"
if [[ -f "$GI" ]]; then
  if ! grep -qF '.orca/orchestration/handles.json' "$GI" 2>/dev/null; then
    printf '\n# Orca local terminal handles\n.orca/orchestration/handles.json\n' >> "$GI"
    echo "  updated .gitignore"
  fi
else
  printf '# Orca local terminal handles\n.orca/orchestration/handles.json\n' > "$GI"
  echo "  created .gitignore"
fi

# Optional AGENTS.md snippet if AGENTS.md exists and lacks section
AGENTS="$ROOT/AGENTS.md"
MARKER="## Orca Role Orchestration"
if [[ -f "$AGENTS" ]] && ! grep -qF "$MARKER" "$AGENTS" 2>/dev/null; then
  cat >> "$AGENTS" <<EOF

$MARKER

| Role | Model | CLI |
|------|-------|-----|
| architect | Claude Opus 4.8 | \`claude\` |
| executor | GPT-5.6 Sol | \`codex\` |
| thrifty | Grok 4.5 | \`grok\` |
| fallback | Gemini 3.5 Flash (Medium) | \`agy\` |

- SSOT: \`.orca/orchestration/roles.yaml\`
- Playbook: \`.orca/orchestration/PLAYBOOK.md\`
- Bootstrap: \`./scripts/orca-bootstrap-roles.sh\`
- Dispatch: \`./scripts/orca-dispatch-role.sh <role> --spec "…"\`
- Limit failover: \`./scripts/orca-fallback-on-limit.sh --from <role> --spec "…"\`
EOF
  echo "  appended Orca section to AGENTS.md"
fi

echo "Done."
echo "Next:"
echo "  1) Customize .orca/orchestration/roles.yaml project_hints if needed"
echo "  2) orca repo add --path $ROOT   # if not already in Orca"
echo "  3) ./scripts/orca-bootstrap-roles.sh --worktree path:$ROOT"
