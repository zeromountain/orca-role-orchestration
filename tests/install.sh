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

# --- T9 debate scaffold ---
assert T9_script_debate "[[ -x \"$ORCH/scripts/orca-debate.sh\" ]]"
assert T9_script_round "[[ -x \"$ORCH/scripts/orca-debate-round.sh\" ]]"
assert T9_script_lib "[[ -f \"$ORCH/scripts/orca-debate-lib.sh\" ]]"
assert T9_personas "[[ -f \"$ORCH/personas/debater_claude.md\" && -f \"$ORCH/personas/debater_gemini.md\" ]]"
# Scope each grep to the section it names. A bare file-wide grep passes on a
# partial rollback, because dags.idea_debate independently contains both
# literals — the role block and the routing entry could both be gone while
# the assertion still reported green.
assert T9_roles_yaml \
  "awk '/^roles:/,/^routing_table:/' \"$ORCH/roles.yaml\" | grep -q 'debater_claude:'"
assert T9_routing \
  "awk '/^routing_table:/,/^dags:/' \"$ORCH/roles.yaml\" | grep -q 'match: idea_debate'"
assert T9_gitignore "grep -q '.orca/orchestration/debates' \"$tmpdir/.gitignore\""
assert T9_no_round_prompts "! grep -q 'Weakest link' \"$ORCH/roles.yaml\""

# T9_gitignore_no_dup: $ORCH's gitignore has been through T1 (fresh), T2 (re-run),
# T3, T4, T5 (fork), T6 (--reset) by this point in the script — a real idempotency
# check across many re-runs, not just the single re-run T2 covers for other files.
gi_debate_count=$(grep -c '.orca/orchestration/debates/' "$tmpdir/.gitignore" 2>/dev/null || true)
assert T9_gitignore_no_dup "[[ \"$gi_debate_count\" -eq 1 ]]"

# --- T10 role metadata is single-sourced ---
assert T10_bootstrap_no_stale "! grep -qE 'claude-opus-4-8|Gemini 3\\.5' \"$ORCH/scripts/orca-bootstrap-roles.sh\""

# T10_agents_no_stale: the brief's original assertion checked $tmpdir/AGENTS.md
# (== $ORCH/../../AGENTS.md), but T1's install target never has an AGENTS.md —
# the installer only appends to one that already exists (install-to-project.sh
# "Optional AGENTS.md snippet" step) — so `! grep ... nonexistent-file` is
# vacuously true even before any fix, and the brief's trailing `|| true` makes
# it doubly unfalsifiable. Exercise the real append path instead: seed a stub
# AGENTS.md in a fresh project root, install for real, check the roster.
agentsdir="$(mktemp -d)"
printf '# Test Project\n' > "$agentsdir/AGENTS.md"
"$INSTALL" --project-root "$agentsdir" --project-name agents-test >/tmp/install-t10.out
assert T10_agents_no_stale "! grep -qE 'Opus 4\\.8|Gemini 3\\.5' \"$agentsdir/AGENTS.md\""
assert T10_agents_debater "grep -q 'debater_' \"$agentsdir/AGENTS.md\""
rm -rf "$agentsdir"

# --- T11 repo-wide stale-model regression guard ---
# Task 7 fixed the same single-source violation in orca-bootstrap-roles.sh
# (T10 above); Task 8 swept the rest of the shipped repo. This asserts it can't
# quietly come back. Two exclusions, deliberately narrow:
#   - docs/superpowers/  historical specs and plans that record what was true
#     when they were written; rewriting them would falsify the project history,
#     not fix a bug.
#   - tests/install.sh   this file. It carries the legacy-migration fixture at
#     line ~92 (a deliberate `claude-opus-4-8` that exercises the pre-refresh
#     migration path — see T7) and the guard pattern's own literals a few lines
#     below would otherwise match this very assertion.
# `git grep` (not a raw recursive grep) so this only ever sees tracked files —
# no .git internals, no local build/test scratch — and pathspec `:(exclude)`
# scopes out just those paths, nothing else.
#   - CHANGELOG.md  same treatment as docs/superpowers/ below: it records a
#     bug's OLD behavior (the model string a fix corrected away from), and
#     rewriting that description would falsify the history it exists to keep.
STALE_RE='claude-opus-4-8|Opus 4[.]8|Gemini 3[.]5'
stale_hits="$(git -C "$ROOT" grep -InE "$STALE_RE" -- \
  ':(exclude)docs/superpowers' ':(exclude)tests/install.sh' ':(exclude)CHANGELOG.md' 2>/dev/null || true)"
if [[ -n "$stale_hits" ]]; then
  echo "  stale model strings found outside the excluded paths:" >&2
  echo "$stale_hits" | sed 's/^/    /' >&2
fi
assert T11_no_stale_models "[[ -z \"\$stale_hits\" ]]"

# --- T12 orphan sweeper / dead-man watchdog scaffold (Task 2) ---
assert T12_script_sweep "[[ -x \"$ORCH/scripts/orca-sweep-orphans.sh\" ]]"
assert T12_gitignore_locks "grep -qF '.orca/orchestration/debate-locks/' \"$tmpdir/.gitignore\""
# $tmpdir's .gitignore has been through T1 (fresh), T2 (re-run), T3, T4, T5,
# T6 (--reset), and any of the re-runs above by this point — matching the
# existing T9_gitignore_no_dup pattern, this is a real idempotency check
# across many re-runs, not just a single one.
gi_locks_count=$(grep -cF '.orca/orchestration/debate-locks/' "$tmpdir/.gitignore" 2>/dev/null || true)
assert T12_gitignore_no_dup "[[ \"$gi_locks_count\" -eq 1 ]]"

# --- T13 label map / manifest scaffold (Task 3) — same local-runtime-state
# gitignore treatment as debate-locks/ above, since both hold local, never-
# committed driver bookkeeping.
assert T13_gitignore_labels "grep -qF '.orca/orchestration/debate-labels/' \"$tmpdir/.gitignore\""
assert T13_gitignore_manifests "grep -qF '.orca/orchestration/debate-manifests/' \"$tmpdir/.gitignore\""
gi_labels_count=$(grep -cF '.orca/orchestration/debate-labels/' "$tmpdir/.gitignore" 2>/dev/null || true)
assert T13_gitignore_labels_no_dup "[[ \"$gi_labels_count\" -eq 1 ]]"

# --- T14 orca-status.sh ships and is executable ---
assert T14_script_status "[[ -x \"$ORCH/scripts/orca-status.sh\" ]]"
assert T14_gitignore_ledger "grep -qF '.orca/orchestration/dispatch-ledger.jsonl' \"$tmpdir/.gitignore\""
assert T14_gitignore_reapers "grep -qF '.orca/orchestration/reapers/' \"$tmpdir/.gitignore\""
assert T14_gitignore_lock "grep -qF '.orca/orchestration/*.lock' \"$tmpdir/.gitignore\""

# --- T15 dry-run writes nothing ---
dry="$(mktemp -d)"
"$INSTALL" --project-root "$dry" --project-name dry-app --dry-run >/tmp/install-t15.out 2>&1
assert T15_no_scaffold "[[ ! -d \"$dry/.orca\" ]]"
assert T15_no_gitignore "[[ ! -f \"$dry/.gitignore\" ]]"
assert T15_reports_work "grep -q 'would install' /tmp/install-t15.out"
# dry-run on an existing install must not touch it either
cp "$ORCH/roles.yaml" "$tmpdir/roles.before"
"$INSTALL" --project-root "$tmpdir" --project-name test-app --dry-run >/tmp/install-t15b.out 2>&1
assert T15_existing_untouched "cmp -s \"$tmpdir/roles.before\" \"$ORCH/roles.yaml\""
rm -rf "$dry"

# --- T16 .bak rotation keeps older forks ---
# A fork used to survive one upgrade then vanish on the next, when .bak was
# overwritten by the newly-replaced file.
printf '\n# FORK_ONE\n' >> "$ORCH/scripts/orca-status.sh"
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t16a.out 2>&1
assert T16_bak_has_fork_one "grep -q FORK_ONE \"$ORCH/scripts/orca-status.sh.bak\""
printf '\n# FORK_TWO\n' >> "$ORCH/scripts/orca-status.sh"
"$INSTALL" --project-root "$tmpdir" --project-name test-app >/tmp/install-t16b.out 2>&1
assert T16_bak_has_fork_two "grep -q FORK_TWO \"$ORCH/scripts/orca-status.sh.bak\""
assert T16_older_fork_kept "grep -rq FORK_ONE \"$ORCH/scripts/\""

# --- T17 uninstall keeps user-owned files ---
un="$(mktemp -d)"
"$INSTALL" --project-root "$un" --project-name un-app >/tmp/install-t17a.out 2>&1
UORCH="$un/.orca/orchestration"
printf '{"thrifty":{"model":"x"}}\n' > "$UORCH/roles.local.json"
printf '\n# MY_FORK\n' >> "$UORCH/personas/thrifty.md"
"$INSTALL" --project-root "$un" --uninstall >/tmp/install-t17b.out 2>&1
assert T17_scripts_gone "[[ ! -f \"$UORCH/scripts/orca-dispatch-role.sh\" ]]"
assert T17_status_gone "[[ ! -f \"$UORCH/scripts/orca-status.sh\" ]]"
assert T17_roles_gone "[[ ! -f \"$UORCH/roles.yaml\" ]]"
assert T17_hints_kept "[[ -f \"$UORCH/project_hints.yaml\" ]]"
assert T17_local_kept "[[ -f \"$UORCH/roles.local.json\" ]]"
assert T17_fork_kept "grep -q MY_FORK \"$UORCH/personas/thrifty.md\""
assert T17_clean_persona_gone "[[ ! -f \"$UORCH/personas/architect.md\" ]]"
assert T17_reports_kept "grep -q 'Kept' /tmp/install-t17b.out"
rm -rf "$un"

# --- T18 roles.local.json override survives upgrade and --reset ---
ov="$(mktemp -d)"
"$INSTALL" --project-root "$ov" --project-name ov-app >/tmp/install-t18a.out 2>&1
OVORCH="$ov/.orca/orchestration"
printf '{"thrifty":{"model":"claude-sonnet-5"}}\n' > "$OVORCH/roles.local.json"
"$INSTALL" --project-root "$ov" --project-name ov-app >/tmp/install-t18b.out 2>&1
assert T18_survives_upgrade "grep -q claude-sonnet-5 \"$OVORCH/roles.local.json\""
"$INSTALL" --project-root "$ov" --project-name ov-app --reset >/tmp/install-t18c.out 2>&1
assert T18_survives_reset "grep -q claude-sonnet-5 \"$OVORCH/roles.local.json\""
rm -rf "$ov"

echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
echo "Ship gate T2/T3/T5/T7 covered."
exit 0
