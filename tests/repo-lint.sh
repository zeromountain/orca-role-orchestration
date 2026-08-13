#!/usr/bin/env bash
# Repo-structure checks that need no Orca runtime. Runnable locally and in CI.
#   - the four plugin manifests are valid JSON with the keys their host needs
#   - every Claude command has its Codex prompt twin (and vice versa)
#   - templates/personas is complete (delegates to check-personas.sh)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

echo "=== tests/repo-lint.sh ==="

# --- plugin manifests parse ---
for m in \
  ".claude-plugin/plugin.json" \
  ".claude-plugin/marketplace.json" \
  ".codex-plugin/plugin.json" \
  ".agents/plugins/marketplace.json"; do
  assert "json_$(basename "$(dirname "$m")")_$(basename "$m")" \
    "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \"$ROOT/$m\""
done

# --- manifest invariants that silently break a marketplace ---
assert claude_marketplace_source_self \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"plugins\"][0][\"source\"]==\"./\" else 1)' \"$ROOT/.claude-plugin/marketplace.json\""
assert codex_skills_root \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"skills\")==\"./\" else 1)' \"$ROOT/.codex-plugin/plugin.json\""
# Empty hooks keeps Claude hooks from leaking into Codex — a deliberate choice.
assert codex_hooks_empty \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"hooks\")=={} else 1)' \"$ROOT/.codex-plugin/plugin.json\""
# plugin.json deliberately omits version (SHA-based update channel).
assert claude_plugin_no_version \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if \"version\" in d else 0)' \"$ROOT/.claude-plugin/plugin.json\""

# --- command / prompt pairing ---
# Both directories share the SAME filename now (commands/orca-dispatch.md <->
# prompts/orca-dispatch.md) — Claude commands were renamed to match Codex's
# prompt naming so a bare `/orca-dispatch` is unambiguous in Claude Code
# v2.1.216+ even alongside other installed plugins (see CLAUDE.md).
for c in "$ROOT"/commands/*.md; do
  base="$(basename "$c")"
  assert "pair_prompt_exists_${base%.md}" "[[ -f \"$ROOT/prompts/$base\" ]]"
done
for p in "$ROOT"/prompts/*.md; do
  base="$(basename "$p")"
  assert "pair_command_exists_${base%.md}" "[[ -f \"$ROOT/commands/$base\" ]]"
done

# --- personas ---
if "$ROOT/scripts/check-personas.sh" >/dev/null 2>&1; then
  echo "  PASS  personas_lint"
  pass=$((pass + 1))
else
  echo "  FAIL  personas_lint (run scripts/check-personas.sh for detail)"
  fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
