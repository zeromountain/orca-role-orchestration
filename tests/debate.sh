#!/usr/bin/env bash
# Unit tests for the debate library and role-library additions.
# Pure: no Orca runtime required.
set -euo pipefail
# assert() runs its command as an `if` condition, which -e never trips on.
# Any other command expected to fail must be if-guarded (see the quorum test).

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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "=== tests/debate.sh (tmp=$tmpdir) ==="

# shellcheck source=../scripts/orca-roles-lib.sh
source "$ROOT/scripts/orca-roles-lib.sh"

# --- R1 debater metadata ---
assert R1_claude_title  "[[ \"\$(role_meta debater_claude | cut -f1)\" == 'debate-opus' ]]"
assert R1_claude_model  "[[ \"\$(role_meta debater_claude | cut -f2)\" == 'claude-opus-5' ]]"
assert R1_codex_title   "[[ \"\$(role_meta debater_codex | cut -f1)\" == 'debate-sol' ]]"
assert R1_grok_agent    "[[ \"\$(role_meta debater_grok | cut -f3)\" == 'grok' ]]"
assert R1_gemini_agent  "[[ \"\$(role_meta debater_gemini | cut -f3)\" == 'antigravity' ]]"
assert R1_launch_gemini "role_launch_cmd debater_gemini | grep -q 'Gemini 3.6 Flash'"
assert R1_body_codex    "role_fallback_body debater_codex | grep -qi 'feasibility'"

# --- R2 is_debater ---
assert R2_yes "is_debater debater_claude"
assert R2_no  "! is_debater architect"

# --- R3 dispatch_tail_block ---
assert R3_close_has_close   "dispatch_tail_block term_x close   | grep -q 'orca terminal close'"
assert R3_persist_no_close  "! dispatch_tail_block term_x persist | grep -q 'orca terminal close'"
assert R3_persist_says_stay "dispatch_tail_block term_x persist | grep -q 'STAY-OPEN'"
assert R3_persist_handle    "dispatch_tail_block term_x persist | grep -q 'term_x'"

# --- R4 seed_text ---
assert R4_debater_no_close "! seed_text debater_grok grok-4.5 'body' | grep -q 'terminal close'"
assert R4_debater_stays    "seed_text debater_grok grok-4.5 'body' | grep -q 'stay open'"
assert R4_normal_closes    "seed_text architect claude-opus-5 'body' | grep -q 'terminal close'"
assert R4_body_included    "seed_text architect claude-opus-5 'MARKER_BODY' | grep -q 'MARKER_BODY'"

# --- R5 dispatch/close role whitelists ---
DISPATCH="$ROOT/scripts/orca-dispatch-role.sh"

# Both role-whitelist scripts are sandboxed into separate directories under
# $tmpdir before being invoked here, so this file's "Pure: no Orca runtime
# required" claim (see top of file) holds unconditionally rather than merely
# by accident of the checkout's current state. Concretely:
#
#   orca-dispatch-role.sh checks handles.json *before* its role whitelist (by
#   design — an accepted role must still fail on missing handles.json). A
#   direct invocation against the real repo (which has no handles.json) would
#   hit that check for every role, junk or accepted, and never reach the
#   whitelist at all. dispatch_sandbox gets a STUB handles.json one level up
#   so the whitelist is actually exercised — safely, since with no --spec an
#   accepted role still exits cleanly at "--spec or --spec-file required"
#   before any orca/python3 call.
#
#   orca-close-role.sh checks its whitelist *before* handles.json, so an
#   accepted role in a direct invocation would fall through to handles_get →
#   terminal_is_live → `orca terminal close`, i.e. it would make real calls
#   into a live, functional `orca` CLI the moment a handles.json exists at the
#   repo root (e.g. after `orca-bootstrap-roles.sh` runs) — latent today only
#   because that file happens to be absent. close_sandbox deliberately gets
#   NO handles.json, so an accepted role stops at the script's own "No
#   .../handles.json — nothing to close (ok)" branch and never reaches
#   handles_get or any orca call, regardless of what exists at the real repo
#   root.
#
# The two sandboxes are separate directories (not shared) precisely because
# one needs a stub handles.json and the other must never have one.
dispatch_sandbox="$tmpdir/dispatch-sandbox/scripts"
mkdir -p "$dispatch_sandbox"
cp "$ROOT/scripts/orca-dispatch-role.sh" "$ROOT/scripts/orca-roles-lib.sh" "$dispatch_sandbox/"
echo '{}' >"$tmpdir/dispatch-sandbox/handles.json"
DISPATCH_SANDBOXED="$dispatch_sandbox/orca-dispatch-role.sh"

close_sandbox="$tmpdir/close-sandbox/scripts"
mkdir -p "$close_sandbox"
cp "$ROOT/scripts/orca-close-role.sh" "$ROOT/scripts/orca-roles-lib.sh" "$close_sandbox/"
CLOSE_SANDBOXED="$close_sandbox/orca-close-role.sh"

# Capture output and exit status separately from the grep check. Under
# `set -o pipefail` (this file), a script that legitimately exits 1 on its error
# path would otherwise dominate the pipeline's exit status and mask (or, behind a
# leading `!`, falsely flip) whatever grep actually matched. Capturing first and
# grepping the captured string keeps the assertion honest.
r5_dispatch_junk_out="$("$DISPATCH_SANDBOXED" not_a_role 2>&1 || true)"
r5_close_junk_out="$("$CLOSE_SANDBOXED" not_a_role 2>&1 || true)"

# Unknown roles must be rejected with the role error, not a handles error.
assert R5_dispatch_rejects_junk \
  "printf '%s' \"\$r5_dispatch_junk_out\" | grep -q 'role must be'"
assert R5_close_rejects_junk \
  "printf '%s' \"\$r5_close_junk_out\" | grep -q 'role must be'"

# Accepted roles get past the whitelist and fail later for an unrelated reason
# (dispatch: missing --spec; close: missing handles.json) — never "role must be".
for r in ui reviewer debater_claude debater_codex debater_grok debater_gemini; do
  d_out="$("$DISPATCH_SANDBOXED" "$r" 2>&1 || true)"
  c_out="$("$CLOSE_SANDBOXED" "$r" 2>&1 || true)"
  assert "R5_dispatch_accepts_$r" \
    "! printf '%s' \"\$d_out\" | grep -q 'role must be'"
  assert "R5_close_accepts_$r" \
    "! printf '%s' \"\$c_out\" | grep -q 'role must be'"
done

# --- R6 --persist is documented and parsed ---
# ROLE is a required positional arg consumed before the option loop, so bare
# `--help` (no role) never reaches the -h|--help branch; use a placeholder role.
r6_usage_out="$("$DISPATCH" dummy --help 2>&1 || true)"
assert R6_usage_persist "printf '%s' \"\$r6_usage_out\" | grep -q -- '--persist'"
# Tied to the --persist branch itself (not just any NO_REAP=1 in the file — the
# pre-existing --no-reap branch already contains that literal substring).
assert R6_persist_implies_noreap "grep -q -- '--persist).*NO_REAP=1' \"$DISPATCH\""

# `source` is a POSIX "special builtin": under `set -e`, its own file-not-found
# failure kills the whole script immediately, bypassing `|| true` and even an
# `if source ...; then` guard (verified against this repo's bash 3.2). So this
# checks existence first and never calls `source` on a path that isn't there.
# shellcheck source=../scripts/orca-debate-lib.sh
if [[ -f "$ROOT/scripts/orca-debate-lib.sh" ]]; then
  source "$ROOT/scripts/orca-debate-lib.sh"
fi

# --- D1 name mapping ---
assert D1_role_key   "[[ \"\$(debate_role_key grok)\" == 'debater_grok' ]]"
assert D1_short      "[[ \"\$(debate_short_name debater_gemini)\" == 'gemini' ]]"
assert D1_default    "[[ \"\$DEBATERS_DEFAULT\" == 'claude,codex,grok,gemini' ]]"

# --- D2 slugify ---
assert D2_spaces  "[[ \"\$(debate_slugify 'Local First Note App')\" == 'local-first-note-app' ]]"
assert D2_punct   "[[ \"\$(debate_slugify 'A/B: test!!')\" == 'a-b-test' ]]"
assert D2_empty   "[[ \"\$(debate_slugify '!!!')\" == 'debate' ]]"

# --- D3 label map ---
MAP="$tmpdir/round-2/label-map.json"
debate_label_map_create "$MAP" "claude,codex,grok,gemini" >/dev/null
assert D3_file    "[[ -f \"$MAP\" ]]"
assert D3_claude  "[[ \"\$(debate_label_of \"$MAP\" claude)\" == 'A' ]]"
assert D3_gemini  "[[ \"\$(debate_label_of \"$MAP\" gemini)\" == 'D' ]]"
# stable across calls
debate_label_map_create "$MAP" "gemini,grok,codex,claude" >/dev/null
assert D3_stable  "[[ \"\$(debate_label_of \"$MAP\" claude)\" == 'A' ]]"

# --- D4 anonymize ---
# Body placeholders deliberately avoid the substring "claude"/"grok" — the H1
# line is what identifies the author and gets dropped; if the body placeholder
# itself contained the debater's name, D4_name_gone could never pass even with
# correct H1-only redaction, since it greps the body, not just the H1.
mkdir -p "$tmpdir/round-1"
printf '# R1 proposal — claude (Principle & risk)\n\nBODY_TEXT_ONE\n' > "$tmpdir/round-1/claude.md"
printf '# R1 proposal — grok (Contrarian)\n\nBODY_TEXT_TWO\n' > "$tmpdir/round-1/grok.md"
debate_anonymize "$MAP" "$tmpdir/round-1" "$tmpdir/round-2" proposal >/dev/null
assert D4_a_exists  "[[ -f \"$tmpdir/round-2/proposal-A.md\" ]]"
assert D4_c_exists  "[[ -f \"$tmpdir/round-2/proposal-C.md\" ]]"
assert D4_body_kept "grep -q BODY_TEXT_ONE \"$tmpdir/round-2/proposal-A.md\""
assert D4_name_gone "! grep -qi 'claude' \"$tmpdir/round-2/proposal-A.md\""
assert D4_missing_skipped "[[ ! -f \"$tmpdir/round-2/proposal-B.md\" ]]"

# --- D5 lint ---
GOOD="$tmpdir/good.md"
cat > "$GOOD" <<'MD'
# x
## Prior art
## Proposals
- Weakest link: yes
## Directions I deliberately rejected
MD
BAD="$tmpdir/bad.md"
printf '## Proposals\n' > "$BAD"
assert D5_good_passes "debate_lint \"$GOOD\" propose >/dev/null"
assert D5_bad_fails   "! debate_lint \"$BAD\" propose >/dev/null"
# debate_lint returns 1 by design here (see file header), so under this file's
# `set -o pipefail` a direct `debate_lint ... | grep ...` pipeline is poisoned:
# pipefail reports the pipeline's status as non-zero (from debate_lint) even
# when grep matches, exactly the gotcha the R5 block above already documents
# and works around. So capture stderr first (guarded with `|| true` since the
# call is expected to fail), then grep the captured text — matching the R5
# pattern instead of piping directly.
d5_bad_report="$(debate_lint "$BAD" propose 2>&1 || true)"
assert D5_bad_reports "printf '%s' \"\$d5_bad_report\" | grep -q 'Prior art'"

# An unrecognized phase must fail closed (debate_required_headings returns 1
# with zero output; a lint that doesn't check that exit status would see an
# empty heading list, run its while-loop zero times, and rubber-stamp "clean"
# for a file it never examined). GOOD is heading-complete for every real
# phase, so the only way either of these can fail is the phase check itself.
assert D5_bad_phase_fails "! debate_lint \"$GOOD\" totally_bogus_phase >/dev/null 2>/dev/null"
d5_bad_phase_out="$(debate_lint "$GOOD" totally_bogus_phase 2>&1 || true)"
assert D5_bad_phase_reports "printf '%s' \"\$d5_bad_phase_out\" | grep -q 'totally_bogus_phase'"

# --- D6 manifest ---
MAN="$tmpdir/manifest.json"
debate_manifest_append "$MAN" claude task_1 completed ok
debate_manifest_append "$MAN" grok task_2 failed forfeit
assert D6_two_rows "[[ \"\$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' \"$MAN\")\" == '2' ]]"
assert D6_flag     "python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[1][\"flags\"])' \"$MAN\" | grep -q forfeit"

# --- D7 spec builders ---
TOPIC="$tmpdir/topic.md"
printf 'TOPIC_MARKER\n' > "$TOPIC"
S1="$(debate_spec propose claude "$tmpdir" 1 "$tmpdir/round-1/claude.md" A "$TOPIC")"
assert D7_propose_topic  "printf '%s' \"\$S1\" | grep -q TOPIC_MARKER"
assert D7_propose_out    "printf '%s' \"\$S1\" | grep -q 'round-1/claude.md'"
assert D7_propose_head   "printf '%s' \"\$S1\" | grep -q '## Prior art'"
assert D7_propose_source "printf '%s' \"\$S1\" | grep -q '미검증'"
assert D7_propose_ro     "printf '%s' \"\$S1\" | grep -q 'Never run git commit'"
S2="$(debate_spec critique codex "$tmpdir" 2 "$tmpdir/round-2/codex.md" B "$TOPIC")"
assert D7_crit_paths "printf '%s' \"\$S2\" | grep -q 'round-2/proposal-'"
assert D7_crit_own   "printf '%s' \"\$S2\" | grep -q 'Proposal B is your own'"
assert D7_crit_head  "printf '%s' \"\$S2\" | grep -q '## Ranking'"
S3="$(debate_spec converge grok "$tmpdir" 3 "$tmpdir/round-3/grok.md" C "$TOPIC")"
assert D7_conv_paths "printf '%s' \"\$S3\" | grep -q 'round-3/critique-'"
assert D7_conv_head  "printf '%s' \"\$S3\" | grep -q '## Dissent'"

echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" -gt 0 ]] && exit 1
exit 0
