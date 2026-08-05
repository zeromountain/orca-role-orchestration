#!/usr/bin/env bash
# Installer regression tests (T1–T8). Exit 0 only if all assert.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$ROOT/scripts/install-to-project.sh"
chmod +x "$INSTALL"

pass=0
fail=0
assert() {
  local name="$1"
  shift
  if eval "$*"; then
    echo "  PASS  $name"
    pass=$((pass + 1))
  else
    echo "  FAIL  $name"
    fail=$((fail + 1))
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "=== tests/install.sh (tmp=$tmpdir) ==="

# --- T1 fresh install ---
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t1.out
ORCH="$tmpdir/.orca/orchestration"
assert T1_roles "[[ -f \"$ORCH/roles.yaml\" ]]"
assert T1_hints "[[ -f \"$ORCH/project_hints.yaml\" ]]"
assert T1_manifest "[[ -f \"$ORCH/install-manifest.json\" ]]"
assert T1_script_boot "[[ -x \"$ORCH/scripts/orca-bootstrap-roles.sh\" ]]"
assert T1_script_disp "[[ -x \"$ORCH/scripts/orca-dispatch-role.sh\" ]]"
assert T1_script_fb "[[ -x \"$ORCH/scripts/orca-fallback-on-limit.sh\" ]]"
assert T1_no_launch "! grep -q launch_command \"$ORCH/roles.yaml\""
assert T1_hints_name "grep -q test-app \"$ORCH/project_hints.yaml\""

# --- T2 idempotent re-run ---
cp -R "$ORCH" "$tmpdir/before"
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t2.out
bak_count=$(find "$ORCH" -name '*.bak' 2>/dev/null | wc -l | tr -d ' ')
assert T2_no_bak "[[ \"$bak_count\" -eq 0 ]]"
assert T2_roles_same "cmp -s \"$tmpdir/before/roles.yaml\" \"$ORCH/roles.yaml\""
assert T2_hints_same "cmp -s \"$tmpdir/before/project_hints.yaml\" \"$ORCH/project_hints.yaml\""
assert T2_script_same "cmp -s \"$tmpdir/before/scripts/orca-dispatch-role.sh\" \"$ORCH/scripts/orca-dispatch-role.sh\""

# --- T3 hints preserved ---
python3 - "$ORCH/project_hints.yaml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace("always_architect: []", 'always_architect: ["src/**"]')
p.write_text(text)
PY
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t3.out
assert T3_hints_kept "grep -q 'src/\\*\\*' \"$ORCH/project_hints.yaml\""

# --- T4 managed advances ---
python3 - "$ORCH/roles.yaml" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = [ln for ln in p.read_text().splitlines() if "image_generation" not in ln]
p.write_text("\n".join(lines) + "\n")
PY
assert T4_pre "! grep -q image_generation \"$ORCH/roles.yaml\""
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t4.out
assert T4_restored "grep -q image_generation \"$ORCH/roles.yaml\""

# --- T5 forked persona preserved ---
printf '\n# FORK_MARKER_T5\n' >> "$ORCH/personas/architect.md"
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t5.out
assert T5_fork_kept "grep -q FORK_MARKER_T5 \"$ORCH/personas/architect.md\""

# --- T6 --reset ---
"$INSTALL" --project-root "$tmpdir" --project-name test-app --reset >/tmp/install-t6.out
assert T6_fork_gone "! grep -q FORK_MARKER_T5 \"$ORCH/personas/architect.md\""
assert T6_bak_has_fork "grep -q FORK_MARKER_T5 \"$ORCH/personas/architect.md.bak\""

# --- T7 legacy migration ---
legacy="$(mktemp -d)"
mkdir -p "$legacy/.orca/orchestration"
cat > "$legacy/.orca/orchestration/roles.yaml" <<'YAML'
version: 1
project: "legacy-app"
worktree: active
roles:
  architect:
    model: claude-opus-4-8
    persona: |
      Old inline persona body.
routing_table:
  - match: architecture_or_plan
    primary: architect
project_hints:
  always_architect: ["legacy/**"]
  notes: |
    keep me
YAML
"$INSTALL" --project-root "$legacy" --project-name legacy-app >/tmp/install-t7.out
LORCH="$legacy/.orca/orchestration"
assert T7_hints "[[ -f \"$LORCH/project_hints.yaml\" ]]"
assert T7_hints_content "grep -q 'legacy/\\*\\*' \"$LORCH/project_hints.yaml\""
assert T7_no_inline "! grep -q 'Old inline persona' \"$LORCH/roles.yaml\""
assert T7_bak "[[ -f \"$LORCH/roles.yaml.bak\" ]]"
assert T7_managed "grep -q routing_table \"$LORCH/roles.yaml\""
rm -rf "$legacy"

# --- T8 no secrets ---
assert T8_no_secrets "! grep -rE '(BEGIN .*PRIVATE KEY|sk-[A-Za-z0-9]{20,})' \"$ORCH\" >/dev/null 2>&1"

# --- T9 dry-run writes nothing ---
dry="$(mktemp -d)"
"$INSTALL" --project-root "$dry" --project-name dry-app --dry-run >/tmp/install-t9.out 2>&1
assert T9_no_scaffold "[[ ! -d \"$dry/.orca\" ]]"
assert T9_no_gitignore "[[ ! -f \"$dry/.gitignore\" ]]"
assert T9_reports_work "grep -q 'would install' /tmp/install-t9.out"
# dry-run on an existing install must not touch it either
cp "$ORCH/roles.yaml" "$tmpdir/roles.before"
"$INSTALL" --project-root "$tmpdir" --project-name test-app --dry-run >/tmp/install-t9b.out 2>&1
assert T9_existing_untouched "cmp -s \"$tmpdir/roles.before\" \"$ORCH/roles.yaml\""
rm -rf "$dry"

# --- T10 .bak rotation keeps older forks ---
# A fork used to survive one upgrade then vanish on the next, when .bak was
# overwritten by the newly-replaced file.
printf '\n# FORK_ONE\n' >> "$ORCH/scripts/orca-status.sh"
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t10a.out 2>&1
assert T10_bak_has_fork_one "grep -q FORK_ONE \"$ORCH/scripts/orca-status.sh.bak\""
printf '\n# FORK_TWO\n' >> "$ORCH/scripts/orca-status.sh"
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t10b.out 2>&1
assert T10_bak_has_fork_two "grep -q FORK_TWO \"$ORCH/scripts/orca-status.sh.bak\""
assert T10_older_fork_kept "grep -rq FORK_ONE \"$ORCH/scripts/\""

# --- T11 uninstall keeps user-owned files ---
un="$(mktemp -d)"
"$INSTALL" --project-root "$un" --project-name un-app >/tmp/install-t11a.out 2>&1
UORCH="$un/.orca/orchestration"
printf '{"thrifty":{"model":"x"}}\n' > "$UORCH/roles.local.json"
printf '\n# MY_FORK\n' >> "$UORCH/personas/thrifty.md"
"$INSTALL" --project-root "$un" --uninstall >/tmp/install-t11b.out 2>&1
assert T11_scripts_gone "[[ ! -f \"$UORCH/scripts/orca-dispatch-role.sh\" ]]"
assert T11_roles_gone "[[ ! -f \"$UORCH/roles.yaml\" ]]"
assert T11_hints_kept "[[ -f \"$UORCH/project_hints.yaml\" ]]"
assert T11_local_kept "[[ -f \"$UORCH/roles.local.json\" ]]"
assert T11_fork_kept "grep -q MY_FORK \"$UORCH/personas/thrifty.md\""
assert T11_clean_persona_gone "[[ ! -f \"$UORCH/personas/architect.md\" ]]"
assert T11_reports_kept "grep -q 'Kept' /tmp/install-t11b.out"
rm -rf "$un"

echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
echo "Ship gate T2/T3/T5/T7 covered."
exit 0
