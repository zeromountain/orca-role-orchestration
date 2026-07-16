#!/usr/bin/env bash
# Install or update Orca role-orchestration scaffold into a project root.
#
# One primary command (idempotent — re-run freely):
#   install-to-project.sh [--project-root PATH] [--project-name NAME]
#
# Recovery:
#   --reset   overwrite managed files AND forked personas (always .bak first)
#
# Managed (always refreshed): roles.yaml, PLAYBOOK, SCRIPTS, scripts, handles.example
# User-owned (create once):   project_hints.yaml
# Personas:                   refresh only if unmodified since last install (hash match)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TPL="$SKILL_DIR/templates"
SCRIPTS_SRC="$SKILL_DIR/scripts"
ROOT=""
PROJECT_NAME=""
RESET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) ROOT="${2:?}"; shift 2 ;;
    --project-name) PROJECT_NAME="${2:?}"; shift 2 ;;
    --reset) RESET=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: install-to-project.sh [--project-root PATH] [--project-name NAME] [--reset]

  (default)  Install or update. Safe to re-run.
             Managed files refresh; project_hints.yaml and forked personas preserved.
  --reset    Overwrite managed files and forked personas (each gets .bak).
EOF
      exit 0
      ;;
    --force|--update|--fresh|--migrate-roles)
      echo "Removed flag: $1" >&2
      echo "Use flagless install for install/update, or --reset for recovery." >&2
      exit 1
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
MANIFEST="$ORCH/install-manifest.json"

skill_version() {
  if git -C "$SKILL_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SKILL_DIR" describe --tags --always --dirty 2>/dev/null || echo "unknown"
  else
    echo "unknown"
  fi
}

VERSION="$(skill_version)"
echo "orca-role-orchestration ${VERSION} → ${ROOT} (project=${PROJECT_NAME})"

mkdir -p "$ORCH" "$SCRIPTS_DST" "$ORCH/personas"

# report lists (bash 3.2 compatible — no mapfile)
REPORT_REFRESHED=()
REPORT_PRESERVED=()
REPORT_INSTALLED=()
REPORT_MIGRATED=()
REPORT_UNCHANGED=()

render_to_tmp() {
  local src="$1"
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
  printf '%s' "$tmp"
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

# Write managed file: bak on content change, skip if identical
write_managed() {
  local src="$1"
  local dst="$2"
  local label="${3:-$dst}"
  local tmp
  tmp="$(render_to_tmp "$src")"
  if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    REPORT_UNCHANGED+=("$label")
    return 0
  fi
  if [[ -f "$dst" ]]; then
    cp "$dst" "${dst}.bak"
  fi
  mv "$tmp" "$dst"
  if [[ "$dst" == *.sh ]]; then
    chmod +x "$dst"
  fi
  if [[ -f "${dst}.bak" ]]; then
    REPORT_REFRESHED+=("$label")
  else
    REPORT_INSTALLED+=("$label")
  fi
}

# --- one-time migration: pre-split roles.yaml → project_hints.yaml ---
if [[ -f "$ORCH/roles.yaml" && ! -f "$ORCH/project_hints.yaml" ]]; then
  python3 - "$ORCH/roles.yaml" "$ORCH/project_hints.yaml" "$TPL/project_hints.yaml" "$PROJECT_NAME" <<'PY'
import pathlib
import re
import shutil
import sys

roles_path, hints_dst, hints_tpl, project_name = sys.argv[1:5]
roles = pathlib.Path(roles_path)
shutil.copyfile(roles_path, roles_path + ".bak")
lines = roles.read_text().splitlines()

project_line = None
hints_block = []
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    if re.match(r"^project:\s*", line):
        project_line = line
        i += 1
        continue
    if re.match(r"^project_hints:\s*$", line):
        hints_block.append(line)
        i += 1
        while i < n and not re.match(r"^[A-Za-z_]", lines[i]):
            hints_block.append(lines[i])
            i += 1
        continue
    i += 1

if project_line is None and not hints_block:
    # No user keys to extract — fall through to template write later
    sys.exit(0)

tpl = pathlib.Path(hints_tpl).read_text().replace("{{PROJECT_NAME}}", project_name)
# Prefer extracted blocks when present
if project_line is None:
    project_line = f'project: "{project_name}"'
if not hints_block:
    # keep template project_hints section
    pathlib.Path(hints_dst).write_text(tpl)
else:
    # header from template + extracted project + extracted hints
    header = []
    for line in tpl.splitlines():
        if line.startswith("project:") or line.startswith("project_hints:"):
            break
        header.append(line)
    body = "\n".join(header + ["", project_line, ""] + hints_block) + "\n"
    pathlib.Path(hints_dst).write_text(body)
print("migrated")
PY
  if [[ -f "$ORCH/project_hints.yaml" ]]; then
    REPORT_MIGRATED+=("project_hints → project_hints.yaml (old SSOT: roles.yaml.bak)")
  fi
fi

# --- user file: create once, never touch again ---
if [[ ! -f "$ORCH/project_hints.yaml" ]]; then
  write_managed "$TPL/project_hints.yaml" "$ORCH/project_hints.yaml" "project_hints.yaml"
  # write_managed may mark installed; that's correct for first create
else
  REPORT_PRESERVED+=("project_hints.yaml")
fi

# --- personas: fork-preserve via manifest hashes ---
OLD_MANIFEST_JSON="{}"
if [[ -f "$MANIFEST" ]]; then
  OLD_MANIFEST_JSON="$(cat "$MANIFEST")"
fi

for p in "$TPL"/personas/*.md; do
  base="$(basename "$p")"
  dst="$ORCH/personas/$base"
  label="personas/$base"
  rendered="$(render_to_tmp "$p")"
  if [[ ! -f "$dst" ]]; then
    mv "$rendered" "$dst"
    REPORT_INSTALLED+=("$label")
    continue
  fi
  prev_hash="$(python3 -c 'import json,sys; m=json.loads(sys.argv[1]); print(m.get("files",{}).get(sys.argv[2],""))' "$OLD_MANIFEST_JSON" "$label" 2>/dev/null || true)"
  cur_hash="$(sha256_file "$dst")"
  if [[ "$RESET" -eq 1 ]]; then
    if ! cmp -s "$rendered" "$dst"; then
      cp "$dst" "${dst}.bak"
      mv "$rendered" "$dst"
      REPORT_REFRESHED+=("$label (reset)")
    else
      rm -f "$rendered"
      REPORT_UNCHANGED+=("$label")
    fi
    continue
  fi
  if [[ -z "$prev_hash" ]]; then
    # pre-manifest install: fail-safe treat as forked
    rm -f "$rendered"
    REPORT_PRESERVED+=("$label (forked/no prior hash)")
    continue
  fi
  if [[ "$cur_hash" == "$prev_hash" ]]; then
    # unmodified since install — safe to refresh to new template
    if cmp -s "$rendered" "$dst"; then
      rm -f "$rendered"
      REPORT_UNCHANGED+=("$label")
    else
      mv "$rendered" "$dst"
      REPORT_REFRESHED+=("$label")
    fi
  else
    rm -f "$rendered"
    REPORT_PRESERVED+=("$label (locally modified)")
  fi
done

# --- managed files: unconditional overwrite (bak on diff) ---
write_managed "$TPL/roles.yaml" "$ORCH/roles.yaml" "roles.yaml"
write_managed "$TPL/PLAYBOOK.md" "$ORCH/PLAYBOOK.md" "PLAYBOOK.md"
write_managed "$TPL/SCRIPTS.md" "$ORCH/SCRIPTS.md" "SCRIPTS.md"
write_managed "$TPL/handles.example.json" "$ORCH/handles.example.json" "handles.example.json"

for s in orca-bootstrap-roles.sh orca-dispatch-role.sh orca-fallback-on-limit.sh orca-roles-lib.sh orca-close-role.sh; do
  write_managed "$SCRIPTS_SRC/$s" "$SCRIPTS_DST/$s" "scripts/$s"
done

# Relocate legacy project/scripts/orca-*.sh if present.
# Never touch the skill package's own scripts/ when installing into the skill repo itself.
OLD_SCRIPTS_DIR="$ROOT/scripts"
if [[ "$ROOT" != "$SKILL_DIR" && -d "$OLD_SCRIPTS_DIR" && "$OLD_SCRIPTS_DIR" != "$SCRIPTS_DST" ]]; then
  for s in orca-bootstrap-roles.sh orca-dispatch-role.sh orca-fallback-on-limit.sh orca-roles-lib.sh orca-close-role.sh; do
    if [[ -f "$OLD_SCRIPTS_DIR/$s" ]]; then
      # Skip if this is the skill source file (same path as SCRIPTS_SRC)
      if [[ "$OLD_SCRIPTS_DIR/$s" -ef "$SCRIPTS_SRC/$s" ]]; then
        continue
      fi
      cp "$OLD_SCRIPTS_DIR/$s" "$OLD_SCRIPTS_DIR/$s.bak"
      rm -f "$OLD_SCRIPTS_DIR/$s"
      REPORT_REFRESHED+=("relocated legacy scripts/$s")
    fi
  done
  rmdir "$OLD_SCRIPTS_DIR" 2>/dev/null || true
fi

# --- write install-manifest.json ---
python3 - "$MANIFEST" "$VERSION" "$ORCH" <<'PY'
import hashlib
import json
import pathlib
import sys
from datetime import datetime, timezone

manifest_path, version, orch = sys.argv[1:4]
orch_p = pathlib.Path(orch)
files = {}
candidates = [
    "roles.yaml",
    "project_hints.yaml",
    "PLAYBOOK.md",
    "SCRIPTS.md",
    "handles.example.json",
]
for rel in candidates:
    p = orch_p / rel
    if p.is_file():
        files[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
for p in sorted((orch_p / "personas").glob("*.md")):
    files[f"personas/{p.name}"] = hashlib.sha256(p.read_bytes()).hexdigest()
for p in sorted((orch_p / "scripts").glob("orca-*.sh")):
    files[f"scripts/{p.name}"] = hashlib.sha256(p.read_bytes()).hexdigest()

data = {
    "skill_version": version,
    "installed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "files": files,
}
pathlib.Path(manifest_path).write_text(json.dumps(data, indent=2) + "\n")
PY

# gitignore handles.json
GI="$ROOT/.gitignore"
if [[ -f "$GI" ]]; then
  if ! grep -qF '.orca/orchestration/handles.json' "$GI" 2>/dev/null; then
    printf '\n# Orca local terminal handles\n.orca/orchestration/handles.json\n' >> "$GI"
    REPORT_REFRESHED+=(".gitignore")
  fi
else
  printf '# Orca local terminal handles\n.orca/orchestration/handles.json\n' > "$GI"
  REPORT_INSTALLED+=(".gitignore")
fi

# Optional AGENTS.md snippet
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

- Managed routing: \`.orca/orchestration/roles.yaml\`
- Project hints (yours): \`.orca/orchestration/project_hints.yaml\`
- Playbook: \`.orca/orchestration/PLAYBOOK.md\`
- Bootstrap: \`.orca/orchestration/scripts/orca-bootstrap-roles.sh\`
- Dispatch: \`.orca/orchestration/scripts/orca-dispatch-role.sh <role> --spec "…"\`
- Limit failover: \`.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role> --spec "…"\`
EOF
  REPORT_REFRESHED+=("AGENTS.md (section appended)")
fi

# --- report ---
print_list() {
  local title="$1"
  shift
  if [[ $# -gt 0 ]]; then
    local joined
    joined=$(printf '%s, ' "$@" | sed 's/, $//')
    echo "  ${title}: ${joined}"
  fi
}

print_list "installed" "${REPORT_INSTALLED[@]+"${REPORT_INSTALLED[@]}"}"
print_list "refreshed" "${REPORT_REFRESHED[@]+"${REPORT_REFRESHED[@]}"}"
print_list "preserved" "${REPORT_PRESERVED[@]+"${REPORT_PRESERVED[@]}"}"
print_list "migrated" "${REPORT_MIGRATED[@]+"${REPORT_MIGRATED[@]}"}"

echo "Done."
echo "Next:"
echo "  1) Customize .orca/orchestration/project_hints.yaml if needed"
echo "  2) orca repo add --path $ROOT   # if not already in Orca"
echo "  3) .orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$ROOT"
echo "Re-run this installer anytime to pull managed updates (roles.yaml, scripts, docs)."
