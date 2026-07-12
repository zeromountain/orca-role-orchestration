#!/usr/bin/env bash
# Install Orca role-orchestration scaffold into a project root.
# Usage:
#   install-to-project.sh [--project-root PATH] [--project-name NAME] [--force] [--update] [--migrate-roles]
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SKILL_DIR/templates"
SCRIPTS_SRC="$SKILL_DIR/scripts"
ROOT=""
PROJECT_NAME=""
FORCE=0
UPDATE=0
MIGRATE=0
BACKUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) ROOT="${2:?}"; shift 2 ;;
    --project-name) PROJECT_NAME="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --update) UPDATE=1; shift ;;
    --migrate-roles) MIGRATE=1; UPDATE=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--project-root PATH] [--project-name NAME] [--force] [--update] [--migrate-roles]"
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
SCRIPTS_DST="$ORCH/scripts"

echo "Installing orca-role-orchestration → $ROOT (project=$PROJECT_NAME)"

mkdir -p "$ORCH" "$SCRIPTS_DST"

if [[ "$UPDATE" -eq 1 ]]; then
  if [[ ! -f "$ORCH/roles.yaml" ]]; then
    echo "No existing install at $ORCH (roles.yaml missing)." >&2
    echo "Run without --update for a fresh install." >&2
    exit 1
  fi
  FORCE=1
  BACKUP=1
  echo "Update mode: refreshing managed files (roles.yaml handled separately)."
fi

install_file() {
  local src="$1"
  local dst="$2"
  local tmp
  tmp="$(mktemp)"
  if [[ "$src" == *.yaml ]] || [[ "$src" == *.md ]]; then
    python3 - "$src" "$tmp" "$PROJECT_NAME" <<'PY'
import pathlib
import sys

source, destination, project_name = sys.argv[1:4]
text = pathlib.Path(source).read_text()
pathlib.Path(destination).write_text(text.replace("{{PROJECT_NAME}}", project_name))
PY
  else
    cp "$src" "$tmp"
  fi
  if [[ -f "$dst" ]]; then
    if cmp -s "$tmp" "$dst"; then
      rm -f "$tmp"; echo "  unchanged: $dst"; return
    fi
    if [[ "$FORCE" -ne 1 ]]; then
      rm -f "$tmp"; echo "  skip existing: $dst (use --force or --update)"; return
    fi
    if [[ "$BACKUP" -eq 1 ]]; then
      cp "$dst" "$dst.bak"; echo "  backed up: $dst.bak"
    fi
  fi
  mv "$tmp" "$dst"
  echo "  wrote $dst"
}

migrate_roles() {
  local target="$1"
  python3 - "$target" <<'PY'
import sys, re, shutil, pathlib

target = sys.argv[1]
lines = pathlib.Path(target).read_text().splitlines()

REPL = {
  "coordinator": [
    "    persona_file: personas/coordinator.md",
    "    persona_summary: >-",
    "      The Conductor — decompose into a DAG, route by model strength, dispatch,",
    "      synthesize; never bulk-implement.",
  ],
  "architect": [
    "    persona_file: personas/architect.md",
    "    persona_summary: >-",
    "      The Strategist — plan, judge, and review high-stakes work with evidence;",
    "      delegate bulk implementation; push back on weak plans.",
  ],
  "executor": [
    "    persona_file: personas/executor.md",
    "    persona_summary: >-",
    "      The Closer — implement the approved plan end-to-end, verify before",
    "      claiming done, integrate; escalate ambiguity to architect.",
  ],
  "thrifty": [
    "    persona_file: personas/thrifty.md",
    "    persona_summary: >-",
    "      The Scout — fast, cheap small/exploratory work; small diffs; cite",
    "      sources; escalate design risk early.",
  ],
  "fallback": [
    "    persona_file: personas/fallback.md",
    "    persona_summary: >-",
    "      The Relief Pitcher — enter only on a primary's limit; smallest viable",
    "      progress; stabilize and hand back; never re-architect.",
  ],
}

def role_of(line):
    m = re.match(r'^  (\w+):\s*$', line)
    return m.group(1) if m else None

has_pf = set()
cur = None
for line in lines:
    r = role_of(line)
    if r:
        cur = r
        continue
    if cur and re.match(r'^    persona_file:', line):
        has_pf.add(cur)

header_present = any('Personas live in personas' in l for l in lines)
out = []
cur = None
i = 0
n = len(lines)
migrated = []
header_done = header_present
while i < n:
    line = lines[i]
    if not header_done and line.startswith('# SSOT for coordinator routing'):
        out.append(line)
        out.append('# Personas live in personas/<role>.md (single source of truth). bootstrap injects')
        out.append("# the full persona into each worker terminal; dispatch injects the file's")
        out.append('# <!-- STANCE: ... --> line as a per-task reminder.')
        header_done = True
        i += 1
        continue
    r = role_of(line)
    if r:
        cur = r
        out.append(line)
        i += 1
        continue
    if cur and re.match(r'^    persona:\s*\|', line):
        if cur in REPL and cur not in has_pf:
            out.extend(REPL[cur])
            migrated.append(cur)
            i += 1
            while i < n and re.match(r'^      ', lines[i]):
                i += 1
        else:
            out.append(line)
            i += 1
            while i < n and re.match(r'^      ', lines[i]):
                out.append(lines[i])
                i += 1
        continue
    if cur == 'coordinator' and re.match(r'^    model:', line) \
            and 'coordinator' not in has_pf and 'coordinator' not in migrated:
        out.append(line)
        out.extend(REPL['coordinator'])
        migrated.append('coordinator')
        i += 1
        continue
    out.append(line)
    i += 1

changed = bool(migrated) or (header_done and not header_present)
if changed:
    shutil.copyfile(target, target + '.bak')
    pathlib.Path(target).write_text("\n".join(out) + "\n")
    print("  migrated roles:", ", ".join(migrated) if migrated else "(header only)")
else:
    print("  roles.yaml already migrated (no change)")
PY
}

if [[ "$UPDATE" -eq 1 ]]; then
  if [[ "$MIGRATE" -eq 1 ]]; then
    migrate_roles "$ORCH/roles.yaml"
  else
    echo "  preserved $ORCH/roles.yaml (customizations kept; --migrate-roles to convert legacy personas)"
  fi
else
  install_file "$TPL/roles.yaml" "$ORCH/roles.yaml"
fi
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
- Bootstrap: \`.orca/orchestration/scripts/orca-bootstrap-roles.sh\`
- Dispatch: \`.orca/orchestration/scripts/orca-dispatch-role.sh <role> --spec "…"\`
- Limit failover: \`.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec "…"\`
EOF
  echo "  appended Orca section to AGENTS.md"
fi

echo "Done."
echo "Next:"
echo "  1) Customize .orca/orchestration/roles.yaml project_hints if needed"
echo "  2) orca repo add --path $ROOT   # if not already in Orca"
echo "  3) .orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$ROOT"
