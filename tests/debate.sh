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
# Task 2's watchdog tests start real background processes (a fake "owner" and
# the real watchdog daemon) against a stubbed orca — never the real runtime.
# CLEANUP_PIDS collects every such pid so the EXIT trap below can force-kill
# anything still alive no matter how/where the suite exits (assertion
# failure, unexpected error under set -e, etc.), so a broken assertion in
# this file can never leak a stray process onto the dev machine.
CLEANUP_PIDS=()
trap 'for _p in "${CLEANUP_PIDS[@]:-}"; do kill -9 "$_p" 2>/dev/null || true; done; rm -rf "$tmpdir"' EXIT

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

# --- E1 round script dry-run (no Orca runtime touched) ---
ROUND="$ROOT/scripts/orca-debate-round.sh"
DEB="$tmpdir/debate"
mkdir -p "$DEB"
printf 'TOPIC_E1\n' > "$DEB/topic.md"

assert E1_exec "[[ -x \"$ROUND\" ]]"
assert E1_needs_args "! \"$ROUND\" >/dev/null 2>&1"

OUT="$("$ROUND" --dir "$DEB" --round 1 --phase propose --dry-run 2>&1)"
assert E1_dry_four   "[[ \"\$(printf '%s' \"\$OUT\" | grep -c '^===== debater_')\" == '4' ]]"
assert E1_dry_topic  "printf '%s' \"\$OUT\" | grep -q TOPIC_E1"
assert E1_dry_nodisp "! printf '%s' \"\$OUT\" | grep -q 'Creating task'"
assert E1_dry_subset "[[ \"\$(\"$ROUND\" --dir \"$DEB\" --round 1 --phase propose --debaters claude,grok --dry-run 2>&1 | grep -c '^===== debater_')\" == '2' ]]"

# --- E2 collection + quorum, with dispatch and polling stubbed ---
STUB="$tmpdir/stubbin"
mkdir -p "$STUB"
cat > "$STUB/orca-dispatch-role.sh" <<'SH'
#!/usr/bin/env bash
# stub: echo a task id, write the debater's output file from the spec's target path
role="$1"; shift
spec=""
while [[ $# -gt 0 ]]; do
  case "$1" in --spec) spec="$2"; shift 2 ;; *) shift ;; esac
done
target="$(printf '%s' "$spec" | grep -m1 -o '/[^ ]*/round-[0-9]*/[a-z]*\.md')"
mkdir -p "$(dirname "$target")"
{
  echo "# stub"
  echo "## Prior art"
  echo "## Proposals"
  echo "- Weakest link: stub"
  echo "## Directions I deliberately rejected"
} > "$target"
echo "task_id=task_${role}"
SH
chmod +x "$STUB/orca-dispatch-role.sh"

DEB2="$tmpdir/debate2"
mkdir -p "$DEB2"
printf 'TOPIC_E2\n' > "$DEB2/topic.md"
ORCA_TEST_DISPATCH="$STUB/orca-dispatch-role.sh" \
ORCA_TEST_STATUS_STUB=completed \
"$ROUND" --dir "$DEB2" --round 1 --phase propose --timeout-ms 5000 >/dev/null 2>&1
assert E2_files "[[ -f \"$DEB2/round-1/claude.md\" && -f \"$DEB2/round-1/gemini.md\" ]]"
assert E2_manifest "[[ -f \"$DEB2/round-1/manifest.json\" ]]"
assert E2_anon "[[ -f \"$DEB2/round-2/proposal-A.md\" ]]"
assert E2_map "[[ -f \"$DEB2/round-2/label-map.json\" ]]"

# quorum failure: stub reports failed for everyone
DEB3="$tmpdir/debate3"
mkdir -p "$DEB3"
printf 'TOPIC_E3\n' > "$DEB3/topic.md"
# The round script exits 2 here by design, so the call must be if-guarded:
# tests/debate.sh runs under `set -e`, which would otherwise abort the suite.
if ORCA_TEST_DISPATCH="$STUB/orca-dispatch-role.sh" \
   ORCA_TEST_STATUS_STUB=failed \
   "$ROUND" --dir "$DEB3" --round 1 --phase propose --timeout-ms 5000 >/dev/null 2>&1; then
  QUORUM_RC=0
else
  QUORUM_RC=$?
fi
assert E2_quorum_exit "[[ $QUORUM_RC -eq 2 ]]"
assert E2_quorum_no_anon "[[ ! -f \"$DEB3/round-2/proposal-A.md\" ]]"

# --- E4 a single dispatcher failure is forfeited, not fatal ---
# Regression for `tid=$(dispatch | awk ...)` under `set -euo pipefail`: if the
# real dispatcher exits non-zero mid-fanout, pipefail makes that assignment's
# exit status non-zero and (per the same `local`-vs-bare-assignment rule
# documented in orca-debate-lib.sh's debate_lint) a bare `tid=$(...)` is NOT
# exempt from `set -e` the way a `local tid=$(...)` would be — so the whole
# round script would abort mid-fanout instead of forfeiting just that debater.
cat > "$STUB/orca-dispatch-role-fail1.sh" <<'SH'
#!/usr/bin/env bash
# stub: same as orca-dispatch-role.sh, but debater_codex's dispatch fails outright.
role="$1"; shift
spec=""
while [[ $# -gt 0 ]]; do
  case "$1" in --spec) spec="$2"; shift 2 ;; *) shift ;; esac
done
if [[ "$role" == "debater_codex" ]]; then
  echo "stub: simulated dispatcher failure" >&2
  exit 1
fi
target="$(printf '%s' "$spec" | grep -m1 -o '/[^ ]*/round-[0-9]*/[a-z]*\.md')"
mkdir -p "$(dirname "$target")"
{
  echo "# stub"
  echo "## Prior art"
  echo "## Proposals"
  echo "- Weakest link: stub"
  echo "## Directions I deliberately rejected"
} > "$target"
echo "task_id=task_${role}"
SH
chmod +x "$STUB/orca-dispatch-role-fail1.sh"

DEB4="$tmpdir/debate4"
mkdir -p "$DEB4"
printf 'TOPIC_E4\n' > "$DEB4/topic.md"
# Quorum (3 of 4) should still be met, so the round script is expected to exit 0 —
# but capture the real exit code rather than assuming it, since a regression here
# would abort the whole script, not merely flip 0 to 2.
E4_RC=0
ORCA_TEST_DISPATCH="$STUB/orca-dispatch-role-fail1.sh" \
ORCA_TEST_STATUS_STUB=completed \
"$ROUND" --dir "$DEB4" --round 1 --phase propose --timeout-ms 5000 >/dev/null 2>&1 || E4_RC=$?
assert E4_survives_fail   "[[ $E4_RC -eq 0 ]]"
assert E4_others_present  "[[ -f \"$DEB4/round-1/claude.md\" && -f \"$DEB4/round-1/gemini.md\" && -f \"$DEB4/round-1/grok.md\" ]]"
assert E4_forfeit_missing "[[ ! -s \"$DEB4/round-1/codex.md\" ]]"

# --- F1 driver argument handling and preflight ---
DRIVER="$ROOT/scripts/orca-debate.sh"
assert F1_exec "[[ -x \"$DRIVER\" ]]"
assert F1_needs_topic "! \"$DRIVER\" >/dev/null 2>&1"
assert F1_help "\"$DRIVER\" --help | grep -q -- '--judge'"

# A roster that cannot reach three seats must abort before creating anything.
FEW_OUT="$("$DRIVER" --topic 'x' --debaters claude --dry-run 2>&1 || true)"
assert F1_min_roster "printf '%s' \"\$FEW_OUT\" | grep -q 'Fewer than 3'"
assert F1_preflight_probes "grep -q 'command -v' \"$DRIVER\""

# Capture rc and output separately, then grep the captured string. A direct
# `"$DRIVER" ... | grep ...` here would run under this file's `set -o
# pipefail`: the driver correctly exits non-zero for --rounds 9, and pipefail
# reports THAT exit status for the whole pipeline even when grep matches on
# the right — the same masking gotcha the R5/D5 blocks above already document
# and work around (confirmed by direct reproduction: a fake driver that exits
# 1 after printing the target substring makes an unguarded `driver | grep -q
# pattern` assertion report FAIL 100% of the time, regardless of whether the
# substring was actually present). Written as a direct pipe, this assertion
# could never pass no matter how correct --rounds validation is.
f1_rounds_rc=0
f1_rounds_out="$("$DRIVER" --topic 'x' --rounds 9 2>&1)" || f1_rounds_rc=$?
assert F1_rounds_bounded "[[ \"\$f1_rounds_rc\" -ne 0 ]] && printf '%s' \"\$f1_rounds_out\" | grep -q 'must be 1, 2, or 3'"

# --- F4 an unknown debater name is diagnosed, not a silent crash ---
# role_launch_cmd exits 1 for a name it doesn't recognize; a bare
# `cli=$(role_launch_cmd ... | awk ...)` in the preflight loop would let that
# non-zero status kill the whole driver under set -euo pipefail, before
# preflight can report anything (reproduced: exit 1, zero output, for a typo
# in --debaters). Capture rc and output separately, then grep the captured
# string — same masking gotcha as F1_rounds_bounded above.
f4_rc=0
f4_out="$("$DRIVER" --topic 'x' --debaters claude,codex,bogus --dry-run 2>&1)" || f4_rc=$?
assert F4_unknown_named   "printf '%s' \"\$f4_out\" | grep -q 'bogus'"
assert F4_unknown_aborts  "[[ \"\$f4_rc\" -ne 0 ]] && printf '%s' \"\$f4_out\" | grep -q 'Fewer than 3'"

# --- F2 dry-run wiring ---
OUT2="$("$DRIVER" --topic 'Local First Note App' --dir-root "$tmpdir/debates" --dry-run 2>&1)"
assert F2_slug   "printf '%s' \"\$OUT2\" | grep -q 'local-first-note-app'"
assert F2_topic  "[[ -f \"$tmpdir/debates/local-first-note-app/topic.md\" ]]"
assert F2_rounds "[[ \"\$(printf '%s' \"\$OUT2\" | grep -c 'ROUND')\" -ge 3 ]]"
assert F2_slug_override "\"$DRIVER\" --topic 'x' --slug custom-slug --dir-root \"$tmpdir/debates\" --dry-run >/dev/null 2>&1 && [[ -d \"$tmpdir/debates/custom-slug\" ]]"

# --- F3 transcript assembly is pure and testable ---
# A dedicated dir (not $tmpdir/debate4, already owned by the E4 block above)
# — reusing that path would silently mix this fixture with E4's leftover
# round-1/round-2 files (label-map.json, proposal-*.md, gemini.md, grok.md);
# harmless to these specific assertions since the transcript builder filters
# proposal-*/critique-* and the greps below don't assert absence-of-content,
# but there's no reason to depend on that and every reason to keep F3 isolated.
DEBF3="$tmpdir/debate-f3"
mkdir -p "$DEBF3/round-1" "$DEBF3/round-3"
printf 'TOPIC_F3\n' > "$DEBF3/topic.md"
printf '# a\nAAA\n' > "$DEBF3/round-1/claude.md"
printf '# b\nBBB\n' > "$DEBF3/round-3/grok.md"
source "$ROOT/scripts/orca-debate-lib.sh"
"$DRIVER" --build-transcript "$DEBF3" >/dev/null 2>&1
assert F3_transcript "[[ -f \"$DEBF3/transcript.md\" ]]"
assert F3_has_topic  "grep -q TOPIC_F3 \"$DEBF3/transcript.md\""
assert F3_has_both   "grep -q AAA \"$DEBF3/transcript.md\" && grep -q BBB \"$DEBF3/transcript.md\""
assert F3_attributed "grep -q 'claude' \"$DEBF3/transcript.md\""

# --- F5 SIGTERM actually stops the driver (regression for the split trap) ---
# The brief's original code shared one handler across EXIT/INT/TERM
# (`trap cleanup EXIT INT TERM`) with a cleanup() that never calls exit. In
# bash, a trap on a terminating signal whose handler does not itself call
# exit does not stop the script — execution resumes after the interrupted
# command. Concretely: the round loop's `if ! orca-debate-round.sh ...; then
# ...; break; fi` treats that resumed, unsignaled completion as ordinary
# success/failure and keeps going, so a merged trap would let the *dry-run*
# path reach its own unconditional `exit 0` after finishing all 3 rounds —
# regardless of when the signal arrived. The fix (this repo's current code)
# splits INT/TERM into their own traps that call `exit` directly, which both
# truncates remaining execution and still fires the EXIT trap exactly once
# (verified separately on bash 3.2.57).
#
# SIGINT cannot be used to observe this: a non-interactive shell sets SIGINT
# to ignored for an asynchronous (`&`) child, so `kill -INT` on a backgrounded
# script is a no-op there. SIGTERM has no such special-case and is what a
# supervising coordinator would actually send, so it is used here.
#
# Do not signal against a script whose current foreground child is one long
# sleep — bash defers a pending trap until that foreground command returns,
# which would hide the very difference this test exists to catch. Instead,
# poll the driver's own redirected output for proof that round 1 is already
# in flight (so the trap is registered and there is a real round loop to
# interrupt), then send SIGTERM immediately. This makes the assertions below
# robust to scheduling jitter: with the fix, the process always exits 143 and
# never reaches round 3 no matter which moment within round 1 it lands on;
# with the merged-trap regression, it always exits 0 and always reaches round
# 3, because the signal never actually interrupts anything. Verified directly
# (3 runs each, both shapes) before writing this as a permanent assertion.
F5_LOG="$tmpdir/f5-term.log"
: > "$F5_LOG"
"$DRIVER" --topic 'sigterm test' --dir-root "$tmpdir/debates-f5" --dry-run \
  >"$F5_LOG" 2>&1 &
f5_pid=$!

f5_waited_ms=0
while ! grep -q '=== ROUND 1' "$F5_LOG" 2>/dev/null; do
  if ! kill -0 "$f5_pid" 2>/dev/null; then
    break
  fi
  sleep 0.02
  f5_waited_ms=$((f5_waited_ms + 20))
  if [[ "$f5_waited_ms" -ge 5000 ]]; then
    break
  fi
done
kill -TERM "$f5_pid" 2>/dev/null || true

f5_rc=0
wait "$f5_pid" 2>/dev/null || f5_rc=$?

assert F5_sigterm_exit_143 "[[ \"\$f5_rc\" -eq 143 ]]"
assert F5_sigterm_stops    "! grep -q '=== ROUND 3' \"$F5_LOG\""

# --- G1 documentation surface ---
# Positive checks target strings that do not exist anywhere in these docs today
# (verified: no file below mentions the debate driver or the debate mode before
# Task 8's docs land), so each one only goes green once the real documentation
# is written — not merely because the file exists.
assert G1_cmd "[[ -f \"$ROOT/commands/debate.md\" ]]"
assert G1_prompt "[[ -f \"$ROOT/prompts/orca-debate.md\" ]]"
assert G1_skill_mode "grep -q 'orca-debate.sh' \"$ROOT/SKILL.md\""
assert G1_skill_keywords "grep -q '아이디어 토론' \"$ROOT/SKILL.md\""
assert G1_playbook "grep -q 'orca-debate.sh' \"$ROOT/templates/PLAYBOOK.md\""
assert G1_scripts_doc "grep -q 'orca-debate-round.sh' \"$ROOT/templates/SCRIPTS.md\""
assert G1_readme "grep -q 'orca-debate.sh' \"$ROOT/README.md\""
# Stale model strings must be gone from shipped docs. The grep patterns below
# are written with a doubled backslash before each dot on purpose: it collapses
# to a single escaped dot at eval time (correct regex), but the raw source text
# of this line never spells the stale model name as one contiguous run of
# characters — so the repo-wide stale-string guard added to tests/install.sh
# (T11) does not trip on this very line. Confirmed empirically with the guard's
# own pattern run directly against this file.
assert G1_playbook_fresh "! grep -qE 'Opus 4\\.8|Gemini 3\\.5' \"$ROOT/templates/PLAYBOOK.md\""
assert G1_skill_fresh "! grep -qE 'Opus 4\\.8|Gemini 3\\.5' \"$ROOT/SKILL.md\""


# ============================================================================
# Task 1 (terminal lifecycle): H-series. All use a stubbed `orca` on PATH
# prepended inside a subshell — never the real runtime — so this file's
# "Pure: no Orca runtime required" claim keeps holding. Each block gets its
# own $tmpdir subdirectory so ORCH/HANDLES_FILE/journal state never bleeds
# across blocks. ensure_terminal/create_role/seed are called directly as
# functions (not through a wrapper script) since orca-roles-lib.sh is already
# sourced above; wrapping each call in a subshell (rather than a bare
# top-level statement or bare `$(...)` assignment) is what keeps a
# deliberately-failing call from tripping this file's own `set -e` — the
# same masking concern the R5/D5/E2/E4/F1/F4 blocks above already document,
# just applied to library functions instead of external scripts.
# ============================================================================

# --- H1 (Step 1): a create response with no handle still leaves a journal
# line (raw non-null, handle null) — proving the pre-fix code left nothing
# is done once, outside this file, against a scratch copy of the original
# orca-roles-lib.sh (see task-1-report.md); a permanent regression test here
# can only assert the fixed file's behavior, since this file sources the
# fixed library, not the historical one.
h1_dir="$tmpdir/h1"
mkdir -p "$h1_dir/bin" "$h1_dir/orch"
cat > "$h1_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create") echo '{"ok":true,"result":{"terminal":{"title":"no-handle-here"}}}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h1_dir/bin/orca"

h1_rc=0
(
  export PATH="$h1_dir/bin:$PATH"
  WORKTREE=active
  ORCH="$h1_dir/orch"
  HANDLES_FILE="$ORCH/handles.json"
  ensure_terminal architect
) >"$h1_dir/stdout.log" 2>"$h1_dir/stderr.log" || h1_rc=$?

h1_journal="$h1_dir/orch/terminal-journal.jsonl"
assert H1_ensure_terminal_fails "[[ \"$h1_rc\" -ne 0 ]]"
assert H1_journal_written "[[ -s \"$h1_journal\" ]]"
assert H1_journal_handle_null \
  "python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])[\"handle\"])' \"$h1_journal\" | grep -qx None"
assert H1_journal_raw_nonnull \
  "python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])[\"raw\"] is not None)' \"$h1_journal\" | grep -qx True"
assert H1_handles_not_written "[[ ! -f \"$h1_dir/orch/handles.json\" ]]"
assert H1_stdout_empty "[[ ! -s \"$h1_dir/stdout.log\" ]]"

# --- H2 (Step 2): a send failure still leaves the handle in handles.json,
# and reports on stderr rather than being swallowed.
h2_dir="$tmpdir/h2"
mkdir -p "$h2_dir/bin" "$h2_dir/orch"
cat > "$h2_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_h2fail"}}}' ;;
  "terminal rename") echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal send") echo "stub: simulated send failure" >&2; exit 1 ;;
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_h2fail","connected":true}]}}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h2_dir/bin/orca"

h2_rc=0
(
  export PATH="$h2_dir/bin:$PATH"
  WORKTREE=active
  ORCH="$h2_dir/orch"
  HANDLES_FILE="$ORCH/handles.json"
  ensure_terminal architect
) >"$h2_dir/stdout.log" 2>"$h2_dir/stderr.log" || h2_rc=$?

assert H2_ensure_terminal_fails "[[ \"$h2_rc\" -ne 0 ]]"
assert H2_handle_in_handles_json "grep -q term_h2fail \"$h2_dir/orch/handles.json\""
assert H2_stderr_not_swallowed "grep -qi seed \"$h2_dir/stderr.log\""
assert H2_stdout_not_a_ready_handle "! grep -q term_h2fail \"$h2_dir/stdout.log\""

# --- H3: a handles_set failure (simulated via HANDLES_FILE pointing at a
# directory, so python's own open(path) raises) must be caught explicitly —
# ensure_terminal must fail loud and never reach seed at all. This protects
# the "durable before anything that can fail" ordering itself, not just its
# most obvious failure mode (seed).
h3_dir="$tmpdir/h3"
mkdir -p "$h3_dir/bin"
mkdir -p "$h3_dir/orch/handles.json"
cat > "$h3_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_h3"}}}' ;;
  "terminal rename") echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal send")
    touch "$ORCA_H3_MARKER_DIR/send-was-called"
    echo '{"ok":true,"result":{"send":{"handle":"term_h3","accepted":true}}}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h3_dir/bin/orca"

h3_rc=0
(
  export PATH="$h3_dir/bin:$PATH"
  export ORCA_H3_MARKER_DIR="$h3_dir"
  WORKTREE=active
  ORCH="$h3_dir/orch"
  HANDLES_FILE="$ORCH/handles.json"
  ensure_terminal architect
) >"$h3_dir/stdout.log" 2>"$h3_dir/stderr.log" || h3_rc=$?

assert H3_ensure_terminal_fails "[[ \"$h3_rc\" -ne 0 ]]"
assert H3_stderr_mentions_handles_set "grep -qi handles_set \"$h3_dir/stderr.log\""
assert H3_seed_never_called "[[ ! -f \"$h3_dir/send-was-called\" ]]"

# --- H4 (Step 3, unit level): terminal_is_live's three states.
h4_dir="$tmpdir/h4"
mkdir -p "$h4_dir/bin"

cat > "$h4_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"terminals":[{"handle":"term_live","connected":true}]}}'
exit 0
ORCASTUB
chmod +x "$h4_dir/bin/orca"
h4a_rc=0
( export PATH="$h4_dir/bin:$PATH"; terminal_is_live term_live ) || h4a_rc=$?
assert H4_live_is_0 "[[ \"$h4a_rc\" -eq 0 ]]"

cat > "$h4_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"terminals":[{"handle":"term_other","connected":true}]}}'
exit 0
ORCASTUB
chmod +x "$h4_dir/bin/orca"
h4b_rc=0
( export PATH="$h4_dir/bin:$PATH"; terminal_is_live term_missing ) || h4b_rc=$?
assert H4_dead_is_1 "[[ \"$h4b_rc\" -eq 1 ]]"

cat > "$h4_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
echo "boom" >&2
exit 3
ORCASTUB
chmod +x "$h4_dir/bin/orca"
h4c_rc=0
( export PATH="$h4_dir/bin:$PATH"; terminal_is_live term_whatever ) || h4c_rc=$?
assert H4_command_failure_is_2 "[[ \"$h4c_rc\" -eq 2 ]]"

cat > "$h4_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
echo 'not json at all {{{'
exit 0
ORCASTUB
chmod +x "$h4_dir/bin/orca"
h4d_rc=0
( export PATH="$h4_dir/bin:$PATH"; terminal_is_live term_whatever ) || h4d_rc=$?
assert H4_malformed_json_is_2 "[[ \"$h4d_rc\" -eq 2 ]]"

# --- H5 (Step 3, integration): ensure_terminal must NOT create a second
# terminal for a role that already has a handle when liveness is
# undetermined. Pre-fix reproduction (this exact stub against a scratch copy
# of the pre-fix library DID call `terminal create` and overwrite the
# existing handle) is recorded in task-1-report.md.
h5_dir="$tmpdir/h5"
mkdir -p "$h5_dir/bin" "$h5_dir/orch"
cat > "$h5_dir/orch/handles.json" <<'JSON'
{"version":1,"roles":{"architect":{"handle":"term_h5existing"}},"architect":"term_h5existing"}
JSON
cat > "$h5_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create")
    touch "$ORCA_H5_MARKER_DIR/create-was-called"
    echo '{"ok":true,"result":{"terminal":{"handle":"term_h5_SHOULD_NOT_EXIST"}}}'
    ;;
  "terminal list") echo "simulated list failure" >&2; exit 5 ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h5_dir/bin/orca"

h5_rc=0
(
  export PATH="$h5_dir/bin:$PATH"
  export ORCA_H5_MARKER_DIR="$h5_dir"
  WORKTREE=active
  ORCH="$h5_dir/orch"
  HANDLES_FILE="$ORCH/handles.json"
  ensure_terminal architect
) >"$h5_dir/stdout.log" 2>"$h5_dir/stderr.log" || h5_rc=$?

assert H5_ensure_terminal_succeeds "[[ \"$h5_rc\" -eq 0 ]]"
assert H5_returns_existing_handle "grep -qx term_h5existing \"$h5_dir/stdout.log\""
assert H5_no_duplicate_create "[[ ! -f \"$h5_dir/create-was-called\" ]]"
assert H5_handles_json_unchanged \
  "grep -q term_h5existing \"$h5_dir/orch/handles.json\" && ! grep -q SHOULD_NOT_EXIST \"$h5_dir/orch/handles.json\""

# --- H6 (Step 4a): seed refuses a target that isn't term_*-shaped, with a
# distinct message, and never calls `orca` at all.
h6_dir="$tmpdir/h6"
mkdir -p "$h6_dir/bin"
cat > "$h6_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
touch "$ORCA_H6_MARKER_DIR/orca-was-called"
echo '{"ok":true}'
exit 0
ORCASTUB
chmod +x "$h6_dir/bin/orca"

if h6_err="$(
  export PATH="$h6_dir/bin:$PATH"
  export ORCA_H6_MARKER_DIR="$h6_dir"
  seed "not-a-term-handle" architect claude-opus-5 "fallback body" 2>&1
)"; then
  h6_rc=0
else
  h6_rc=$?
fi
assert H6_seed_refuses "[[ \"$h6_rc\" -ne 0 ]]"
assert H6_distinct_message "printf '%s' \"\$h6_err\" | grep -qF 'term_*-shaped'"
assert H6_orca_never_called "[[ ! -f \"$h6_dir/orca-was-called\" ]]"

# --- H7 (Step 4b/4c): seed treats an unaccepted send, and a failed
# read-back, as failures — not just a nonzero `orca terminal send` exit.
h7_dir="$tmpdir/h7"
mkdir -p "$h7_dir/bin"

cat > "$h7_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal send") echo '{"ok":true,"result":{"send":{"handle":"term_h7","accepted":false}}}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h7_dir/bin/orca"
if h7a_err="$(
  export PATH="$h7_dir/bin:$PATH"
  seed "term_h7" architect claude-opus-5 "body" 2>&1
)"; then h7a_rc=0; else h7a_rc=$?; fi
assert H7_not_accepted_fails "[[ \"$h7a_rc\" -ne 0 ]]"
assert H7_not_accepted_message "printf '%s' \"\$h7a_err\" | grep -qi 'not accepted'"

cat > "$h7_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal send") echo '{"ok":true,"result":{"send":{"handle":"term_h7b","accepted":true}}}' ;;
  "terminal read") echo "read failed" >&2; exit 9 ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h7_dir/bin/orca"
if h7b_err="$(
  export PATH="$h7_dir/bin:$PATH"
  seed "term_h7b" architect claude-opus-5 "body" 2>&1
)"; then h7b_rc=0; else h7b_rc=$?; fi
assert H7_readback_failure_fails "[[ \"$h7b_rc\" -ne 0 ]]"
assert H7_readback_message "printf '%s' \"\$h7b_err\" | grep -qi 'could not confirm'"

# --- H8: full happy-path ensure_terminal — the regression net for ordinary
# dispatch of the six real roles. Also proves the exact bytes handed to
# `orca terminal send` for a non-debater role are byte-identical to
# seed_text()'s own output (non-debater seed text is required to stay
# byte-frozen; this checks the wiring, not just the generator function).
h8_dir="$tmpdir/h8"
mkdir -p "$h8_dir/bin" "$h8_dir/orch"
cat > "$h8_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_h8happy"}}}' ;;
  "terminal rename") echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal send")
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text) printf '%s' "$2" > "$ORCA_H8_MARKER_DIR/sent-text.txt"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo '{"ok":true,"result":{"send":{"handle":"term_h8happy","accepted":true}}}'
    ;;
  "terminal read") echo '{"ok":true,"result":{"terminal":{"handle":"term_h8happy","tail":["ROLE=architect on model claude-opus-5"]}}}' ;;
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_h8happy","connected":true}]}}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$h8_dir/bin/orca"

h8_rc=0
(
  unset PROJECT_NAME CONSTRAINTS
  export PATH="$h8_dir/bin:$PATH"
  export ORCA_H8_MARKER_DIR="$h8_dir"
  WORKTREE=active
  ORCH="$h8_dir/orch"
  HANDLES_FILE="$ORCH/handles.json"
  ensure_terminal architect
) >"$h8_dir/stdout.log" 2>"$h8_dir/stderr.log" || h8_rc=$?

assert H8_happy_path_succeeds "[[ \"$h8_rc\" -eq 0 ]]"
assert H8_returns_handle "grep -qx term_h8happy \"$h8_dir/stdout.log\""
assert H8_handles_json_has_handle "grep -q term_h8happy \"$h8_dir/orch/handles.json\""
assert H8_journal_has_handle \
  "python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])[\"handle\"])' \"$h8_dir/orch/terminal-journal.jsonl\" | grep -qx term_h8happy"
EXPECTED_H8_TEXT="$(unset PROJECT_NAME CONSTRAINTS; seed_text architect claude-opus-5 "$(role_fallback_body architect)")"
assert H8_sent_text_byte_exact \
  "diff -q <(printf '%s' \"\$EXPECTED_H8_TEXT\") \"$h8_dir/sent-text.txt\" >/dev/null"

# --- H9: the terminal journal is gitignored the same way handles.json is —
# a behavioral check (real installer run, fresh project + idempotent
# re-run), not a grep of the installer's own source, matching this repo's
# existing T9_gitignore/T9_gitignore_no_dup pattern for handles.json/debates.
# install-to-project.sh is pure bash+python (no `orca` runtime needed), so
# this keeps the "no runtime required" contract.
h9_root="$tmpdir/h9-project"
mkdir -p "$h9_root"
"$ROOT/scripts/install-to-project.sh" --project-root "$h9_root" --project-name h9-test >/dev/null 2>&1
assert H9_gitignore_has_journal "grep -qF '.orca/orchestration/terminal-journal.jsonl' \"$h9_root/.gitignore\""
"$ROOT/scripts/install-to-project.sh" --project-root "$h9_root" --project-name h9-test >/dev/null 2>&1
h9_count=$(grep -cF '.orca/orchestration/terminal-journal.jsonl' "$h9_root/.gitignore" 2>/dev/null || true)
assert H9_gitignore_no_dup "[[ \"$h9_count\" -eq 1 ]]"

# ============================================================================
# Task 2 (orphan sweeper + dead-man watchdog for --persist): L-series (lock
# primitives, pure — no orca, no processes), O-series (sweep mode against a
# stubbed orca), P-series (--persist end-to-end selects STAY-OPEN, via a
# stubbed orca, matching the H-series pattern), W-series (the watchdog
# daemon itself — real background processes against a stubbed orca, never
# the real runtime; every backgrounded pid is appended to CLEANUP_PIDS so
# the file-level EXIT trap force-kills anything still alive no matter how
# this file exits).
# ============================================================================

SWEEP="$ROOT/scripts/orca-sweep-orphans.sh"
assert T2_sweep_exec "[[ -x \"$SWEEP\" ]]"
assert T2_sweep_help "\"$SWEEP\" --help | grep -q -- '--watchdog'"

sw_bad_rc=0
"$SWEEP" --bogus-flag >/dev/null 2>&1 || sw_bad_rc=$?
assert T2_sweep_unknown_flag_rejected "[[ \"$sw_bad_rc\" -ne 0 ]]"

sw_missing_rc=0
"$SWEEP" --watchdog >/dev/null 2>&1 || sw_missing_rc=$?
assert T2_sweep_watchdog_requires_args "[[ \"$sw_missing_rc\" -ne 0 ]]"

# --- L1: lock_write creates the documented shape ---
l_dir="$tmpdir/lock-l1"
mkdir -p "$l_dir"
LFILE="$l_dir/testslug.json"
lock_write "$LFILE" 4242 testslug 1800
assert L1_pid    "[[ \"\$(lock_pid \"$LFILE\")\" == '4242' ]]"
assert L1_empty  "[[ -z \"\$(lock_handles \"$LFILE\")\" ]]"
assert L1_fresh  "lock_is_fresh \"$LFILE\""
assert L1_no_tmp "[[ -z \"\$(find \"$l_dir\" -name '*.tmp.*')\" ]]"

# --- L2: registering against a lock that does not exist is a documented no-op ---
assert L2_noop "! lock_register_handle \"$l_dir/does-not-exist.json\" term_x"

# --- L3/L4: register (with a duplicate) + merge dedups, refreshes heartbeat,
# and empties the sidecar ---
l1_hb_before="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["heartbeatAt"])' "$LFILE")"
lock_register_handle "$LFILE" term_aaa
lock_register_handle "$LFILE" term_bbb
lock_register_handle "$LFILE" term_aaa
assert L3_sidecar_lines "[[ \"\$(wc -l < \"${LFILE%.json}.handles.jsonl\" | tr -d ' ')\" == '3' ]]"
sleep 1
lock_merge_and_refresh "$LFILE"
assert L4_merged_count "[[ \"\$(lock_handles \"$LFILE\" | wc -l | tr -d ' ')\" == '2' ]]"
assert L4_has_aaa "lock_handles \"$LFILE\" | grep -qx term_aaa"
assert L4_has_bbb "lock_handles \"$LFILE\" | grep -qx term_bbb"
assert L4_sidecar_emptied "[[ ! -s \"${LFILE%.json}.handles.jsonl\" ]]"
l1_hb_after="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["heartbeatAt"])' "$LFILE")"
assert L4_heartbeat_refreshed "[[ \"$l1_hb_before\" != \"$l1_hb_after\" ]]"

# --- L5/L6: staleness ---
python3 - "$LFILE" <<'PY'
import json, sys, datetime
path = sys.argv[1]
d = json.load(open(path))
d["heartbeatAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=999999)).isoformat()
d["ttlSeconds"] = 5
with open(path, "w") as f:
    json.dump(d, f)
PY
assert L5_stale "! lock_is_fresh \"$LFILE\""
assert L6_missing_not_fresh "! lock_is_fresh \"$l_dir/nope.json\""

# --- L7: lock_remove removes lock+sidecar; idempotent ---
touch "${LFILE%.json}.handles.jsonl"
lock_remove "$LFILE"
assert L7_lock_gone "[[ ! -f \"$LFILE\" ]]"
assert L7_sidecar_gone "[[ ! -f \"${LFILE%.json}.handles.jsonl\" ]]"
assert L7_idempotent "lock_remove \"$LFILE\""

# ----------------------------------------------------------------------------
# C-series: lock_handle_claimed_elsewhere itself (pure, no orca — direct
# function calls), and the python/sweep-side aggregation it has a sibling
# bug in. Fix round 2: review found (A) the bash function gated on
# lock_is_fresh BEFORE ever checking the owner pid, so a lock whose own
# watchdog died but whose OWNER is still alive was skipped entirely and
# treated as not claiming; and (B) the sweep script's stale_candidates
# dict kept only the FIRST stale lock found (by glob sort order) naming a
# given handle, silently dropping any other claimant — including one with
# a confirmed-alive owner.
# ----------------------------------------------------------------------------
c_dir="$tmpdir/cross-lock-claim"
mkdir -p "$c_dir/locks"
( : ) & c_dead_pid=$!
wait "$c_dead_pid" 2>/dev/null || true

# "exclude" stand-in — its own status never matters, only that it is
# correctly excluded from consideration.
lock_write "$c_dir/locks/c_exclude.json" "$c_dead_pid" cexclude 999999

# --- C1 (Finding A): other lock's heartbeat is STALE but its owner is
# ALIVE — must still be seen as claiming the handle. ---
lock_write "$c_dir/locks/c1_other.json" "$$" c1other 5
lock_register_handle "$c_dir/locks/c1_other.json" term_c1
lock_merge_and_refresh "$c_dir/locks/c1_other.json"
python3 - "$c_dir/locks/c1_other.json" <<'PY'
import json, datetime, sys
path = sys.argv[1]
d = json.load(open(path))
d["heartbeatAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=999)).isoformat()
with open(path, "w") as f:
    json.dump(d, f)
PY
assert C0_c1_other_is_stale "! lock_is_fresh \"$c_dir/locks/c1_other.json\""
assert C0_test_pid_is_alive "kill -0 \"\$\$\""
c1_rc=0
lock_handle_claimed_elsewhere "$c_dir/locks" term_c1 "$c_dir/locks/c_exclude.json" || c1_rc=$?
assert C1_stale_but_owner_alive_is_claimed "[[ \"$c1_rc\" -eq 0 ]]"

# --- C2 (sanity, deadlock-matrix "both dead" half seen from the function
# level): other lock is stale AND its owner is confirmed dead — must NOT
# be seen as claiming. ---
lock_write "$c_dir/locks/c2_other.json" "$c_dead_pid" c2other 5
lock_register_handle "$c_dir/locks/c2_other.json" term_c2
lock_merge_and_refresh "$c_dir/locks/c2_other.json"
python3 - "$c_dir/locks/c2_other.json" <<'PY'
import json, datetime, sys
path = sys.argv[1]
d = json.load(open(path))
d["heartbeatAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=999)).isoformat()
with open(path, "w") as f:
    json.dump(d, f)
PY
c2_rc=0
lock_handle_claimed_elsewhere "$c_dir/locks" term_c2 "$c_dir/locks/c_exclude.json" || c2_rc=$?
assert C2_stale_and_owner_dead_is_not_claimed "[[ \"$c2_rc\" -eq 1 ]]"

# --- C3 (deadlock-matrix "both alive" half): other lock fresh AND its
# owner alive — trivially claimed. ---
lock_write "$c_dir/locks/c3_other.json" "$$" c3other 999999
lock_register_handle "$c_dir/locks/c3_other.json" term_c3
lock_merge_and_refresh "$c_dir/locks/c3_other.json"
c3_rc=0
lock_handle_claimed_elsewhere "$c_dir/locks" term_c3 "$c_dir/locks/c_exclude.json" || c3_rc=$?
assert C3_both_alive_is_claimed "[[ \"$c3_rc\" -eq 0 ]]"

# --- C4/C5 (Finding B): the python/sweep-side aggregation. Two stale
# locks share ONE handle, one owner dead, one owner alive. Protection
# must not depend on which lock name sorts first — tested both ways. ---
c_agg_dir="$tmpdir/cross-lock-agg"
c_agg_orch="$c_agg_dir/orch"
mkdir -p "$c_agg_orch/debate-locks"
# Tracked in handles.json exactly as handles_set would leave it — the same
# realism requirement from the last round's fixture fix applies here too:
# an untracked handle reaches the sweeper via the journal-orphan path
# first (which has its own, unrelated "protected" check and marks the
# handle "seen"), short-circuiting the stale-candidate loop this test
# exists to exercise before it ever runs.
cat > "$c_agg_orch/handles.json" <<'JSON'
{"version":1,"roles":{"debater_claude":{"handle":"term_agg_shared"}},"debater_claude":"term_agg_shared"}
JSON
echo '{"role":"debater_claude","title":"debate-opus","raw":{},"handle":"term_agg_shared","createdAt":"2020-01-01T00:00:00+00:00"}' \
  > "$c_agg_orch/terminal-journal.jsonl"

c_agg_bin="$tmpdir/c-agg-bin"
mkdir -p "$c_agg_bin"
cat > "$c_agg_bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_agg_shared","connected":true}]}}' ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$C_AGG_MARKER"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$c_agg_bin/orca"

push_stale() {
  python3 - "$1" <<'PY'
import json, datetime, sys
path = sys.argv[1]
d = json.load(open(path))
d["heartbeatAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=999)).isoformat()
with open(path, "w") as f:
    json.dump(d, f)
PY
}

first_sorted_lock_pid() {
  # $1=locks_dir -> the "pid" field of whichever *.json file
  # sorted(glob.glob(...)) would visit FIRST. This is the exact traversal
  # order orca-sweep-orphans.sh itself uses (see its stale_candidates
  # construction), reproduced faithfully in python rather than
  # reimplemented in bash, so this proves what the actual production code
  # sees — not what a bash guess at sort order might.
  python3 -c '
import glob, json, os, sys
locks_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(locks_dir, "*.json")))
print(json.load(open(files[0])).get("pid"))
' "$1"
}

run_agg_ordering() {
  # $1=label $2=file_a $3=pid_a $4=file_b $5=pid_b — writes exactly two
  # stale locks with the EXACT (filename, owner pid) pairs given, both
  # naming the shared handle. Deliberately no dead_name/alive_name
  # parameter pair here: an earlier version of this test named parameters
  # by ROLE ("dead_name", "alive_name") rather than by identity, and both
  # call sites happened to pass the alphabetically-first filename as the
  # "dead" parameter regardless of which label the case was given —
  # meaning "dead_first" and "alive_first" wrote the identical fixture
  # (dead pid always in the first-sorting file) under two different
  # names, so the aggregation fix's ability to survive the alive-owner
  # lock sorting first was never actually exercised. Taking the pid
  # directly as an argument for each named file removes any place for
  # that mismatch to hide.
  local label="$1" file_a="$2" pid_a="$3" file_b="$4" pid_b="$5"
  rm -rf "$c_agg_orch/debate-locks"
  mkdir -p "$c_agg_orch/debate-locks"
  lock_write "$c_agg_orch/debate-locks/$file_a" "$pid_a" "slugA_$label" 5
  lock_register_handle "$c_agg_orch/debate-locks/$file_a" term_agg_shared
  lock_merge_and_refresh "$c_agg_orch/debate-locks/$file_a"
  lock_write "$c_agg_orch/debate-locks/$file_b" "$pid_b" "slugB_$label" 5
  lock_register_handle "$c_agg_orch/debate-locks/$file_b" term_agg_shared
  lock_merge_and_refresh "$c_agg_orch/debate-locks/$file_b"
  push_stale "$c_agg_orch/debate-locks/$file_a"
  push_stale "$c_agg_orch/debate-locks/$file_b"

  : > "$c_agg_dir/closed-$label.log"
  (
    export PATH="$c_agg_bin:$PATH"
    export C_AGG_MARKER="$c_agg_dir/closed-$label.log"
    "$SWEEP" --orch-dir "$c_agg_orch" --journal "$c_agg_orch/terminal-journal.jsonl" \
      --handles-file "$c_agg_orch/handles.json" --locks-dir "$c_agg_orch/debate-locks"
  ) >"$c_agg_dir/sweep-$label.out" 2>"$c_agg_dir/sweep-$label.err"
}

c_my_pid="$$"

# dead_first: dead-owner lock ("aaa_dead.json") sorts alphabetically before
# the alive-owner lock ("zzz_alive.json") — this is the exact reviewer
# repro (their "p_dead.json" / "q_alive.json"). Both modes checked:
# report-only (--close was not passed, so the close marker is always
# empty regardless of correctness — the actual signal is the reported
# text) and, separately below (C6), --close for real against a stub.
# "WOULD CLOSE" appearing at all in this single-handle fixture can only be
# about term_agg_shared.
run_agg_ordering dead_first "aaa_dead.json" "$c_dead_pid" "zzz_alive.json" "$c_my_pid"
c_dead_first_first_visited_pid="$(first_sorted_lock_pid "$c_agg_orch/debate-locks")"
assert C4_dead_first_visits_dead_owner_first \
  "[[ \"$c_dead_first_first_visited_pid\" == \"$c_dead_pid\" ]]"
assert C4_agg_dead_first_not_closed "! grep -qx term_agg_shared \"$c_agg_dir/closed-dead_first.log\""
assert C4_agg_dead_first_not_reported_would_close "! grep -q 'WOULD CLOSE' \"$c_agg_dir/sweep-dead_first.out\""
assert C4_agg_dead_first_reason "grep -qi 'owner pid=.*still alive' \"$c_agg_dir/sweep-dead_first.out\""

# alive_first: the SAME two (filename, pid) associations reversed — the
# alive-owner lock ("aaa_alive.json") now sorts first, the dead-owner lock
# ("zzz_dead.json") sorts second. Proven below (C4/C5's own visit-order
# assertions) to be the actual opposite of dead_first's traversal, not
# merely a different label on an identical fixture.
run_agg_ordering alive_first "aaa_alive.json" "$c_my_pid" "zzz_dead.json" "$c_dead_pid"
c_alive_first_first_visited_pid="$(first_sorted_lock_pid "$c_agg_orch/debate-locks")"
assert C5_alive_first_visits_alive_owner_first \
  "[[ \"$c_alive_first_first_visited_pid\" == \"$c_my_pid\" ]]"
assert C5_agg_alive_first_not_closed "! grep -qx term_agg_shared \"$c_agg_dir/closed-alive_first.log\""
assert C5_agg_alive_first_not_reported_would_close "! grep -q 'WOULD CLOSE' \"$c_agg_dir/sweep-alive_first.out\""
assert C5_agg_alive_first_reason "grep -qi 'owner pid=.*still alive' \"$c_agg_dir/sweep-alive_first.out\""

# The point of the whole exercise: the two scenarios' traversal orders are
# genuinely each other's opposite, not the same fixture under two labels.
assert C_orderings_are_genuinely_opposite \
  "[[ \"$c_dead_first_first_visited_pid\" != \"$c_alive_first_first_visited_pid\" ]]"

# --- C6: aggregation must not OVER-protect either — two stale locks
# sharing a handle, BOTH owners confirmed dead, must still become a
# candidate (and, with --close, actually close). ---
rm -rf "$c_agg_orch/debate-locks"
mkdir -p "$c_agg_orch/debate-locks"
lock_write "$c_agg_orch/debate-locks/aaa_dead1.json" "$c_dead_pid" deadslug1 5
lock_register_handle "$c_agg_orch/debate-locks/aaa_dead1.json" term_agg_shared
lock_merge_and_refresh "$c_agg_orch/debate-locks/aaa_dead1.json"
( : ) & c_dead_pid2=$!
wait "$c_dead_pid2" 2>/dev/null || true
lock_write "$c_agg_orch/debate-locks/zzz_dead2.json" "$c_dead_pid2" deadslug2 5
lock_register_handle "$c_agg_orch/debate-locks/zzz_dead2.json" term_agg_shared
lock_merge_and_refresh "$c_agg_orch/debate-locks/zzz_dead2.json"
push_stale "$c_agg_orch/debate-locks/aaa_dead1.json"
push_stale "$c_agg_orch/debate-locks/zzz_dead2.json"
: > "$c_agg_dir/closed-both_dead.log"
c6_rc=0
(
  export PATH="$c_agg_bin:$PATH"
  export C_AGG_MARKER="$c_agg_dir/closed-both_dead.log"
  "$SWEEP" --close --orch-dir "$c_agg_orch" --journal "$c_agg_orch/terminal-journal.jsonl" \
    --handles-file "$c_agg_orch/handles.json" --locks-dir "$c_agg_orch/debate-locks"
) >"$c_agg_dir/sweep-both_dead.out" 2>"$c_agg_dir/sweep-both_dead.err" || c6_rc=$?
assert C6_both_dead_run_exit_ok "[[ \"$c6_rc\" -eq 0 ]]"
assert C6_both_dead_still_closes "grep -qx term_agg_shared \"$c_agg_dir/closed-both_dead.log\""

# ----------------------------------------------------------------------------
# O-series: sweep mode against a stubbed orca. One shared fixture (journal +
# handles.json + debate-locks/), exercised twice with different stub `orca`
# binaries — once where every handle reports live/connected (proving the
# sweeper closes exactly the orphans and nothing else), once where
# `terminal list` itself fails (proving undetermined liveness is always
# left alone, never treated as "safe to close" just because --close was
# passed).
# ----------------------------------------------------------------------------
o_dir="$tmpdir/orphan-sweep"
o_orch="$o_dir/orch"
o_journal="$o_orch/terminal-journal.jsonl"
o_handles="$o_orch/handles.json"
o_locks="$o_orch/debate-locks"
mkdir -p "$o_orch" "$o_locks"

# A guaranteed-dead pid: fork a trivial subshell and `wait` it, so it is
# both dead AND reaped. A hardcoded fake number (e.g. 99998) risks —
# vanishingly unlikely, but not zero — coinciding with a real running
# process on some machine; this is deterministic.
( : ) & o_dead_pid=$!
wait "$o_dead_pid" 2>/dev/null || true

# handles.json exactly as handles_set leaves it: BOTH shapes (top-level
# role=handle AND roles.<role>.handle), for a PRIMARY role (architect,
# which has no lock mechanism at all — handles.json currency is its only
# "in use" signal) and for a DEBATER role (debater_claude). This is the
# fixture shape review found missing: orca-close-role.sh never edits
# handles.json ("next dispatch recreates via ensure_terminal"), so a
# debater's handle sits here PERMANENTLY from creation — tracked whether
# its terminal is alive, closed, or abandoned. Every realistic fixture for
# a debater handle must include it here; omitting it (as an earlier draft
# of this file did) silently masks the exact defect Finding 1 was about.
cat > "$o_handles" <<'JSON'
{"version":1,"roles":{"architect":{"handle":"term_tracked"},"debater_claude":{"handle":"term_stale_candidate"},"debater_codex":{"handle":"term_owner_still_alive"},"debater_grok":{"handle":"term_stale_and_crosslocked"},"debater_gemini":{"handle":"term_sidecar_only_protected"}},"architect":"term_tracked","debater_claude":"term_stale_candidate","debater_codex":"term_owner_still_alive","debater_grok":"term_stale_and_crosslocked","debater_gemini":"term_sidecar_only_protected"}
JSON

lock_write "$o_locks/freshslug.json" 99999 freshslug 999999
lock_register_handle "$o_locks/freshslug.json" term_protected
lock_merge_and_refresh "$o_locks/freshslug.json"

# staleslug: owner pid is the guaranteed-dead pid above — this is the
# realistic "driver AND watchdog both died" scenario Finding 1 is about.
# Its handle (term_stale_candidate) is ALSO tracked in handles.json above,
# exactly as real usage always leaves it.
lock_write "$o_locks/staleslug.json" "$o_dead_pid" staleslug 5
lock_register_handle "$o_locks/staleslug.json" term_stale_candidate
lock_merge_and_refresh "$o_locks/staleslug.json"

# staleslug_alive_owner: heartbeat is ALSO stale (past TTL — its watchdog
# stopped refreshing), but its recorded owner pid ($$, this very test
# process) is very much alive — the debate itself may still be legitimately
# running even though its OWN watchdog died. This must NOT become a
# candidate (R1 finding: presence-in-handles.json is not the protection
# rule, but neither is "heartbeat expired" alone — an alive owner pid is).
lock_write "$o_locks/staleslug_alive_owner.json" "$$" staleslug_alive_owner 5
lock_register_handle "$o_locks/staleslug_alive_owner.json" term_owner_still_alive
lock_merge_and_refresh "$o_locks/staleslug_alive_owner.json"

# staleslug_crosslocked / freshslug_crosslocked: the SAME handle
# (term_stale_and_crosslocked) is named by a stale lock AND, separately, by
# a DIFFERENT lock that is still fresh with a confirmed-alive owner ($$) —
# a second, live debate legitimately sharing the handle (ensure_terminal
# reuses a live role terminal globally). Must NOT become a candidate
# (Finding 2, sweeper side — the same "claimed by another fresh lock"
# reasoning applied to the stale-lock path, not just the journal path).
lock_write "$o_locks/staleslug_crosslocked.json" "$o_dead_pid" staleslug_crosslocked 5
lock_register_handle "$o_locks/staleslug_crosslocked.json" term_stale_and_crosslocked
lock_merge_and_refresh "$o_locks/staleslug_crosslocked.json"
lock_write "$o_locks/freshslug_crosslocked.json" "$$" freshslug_crosslocked 999999
lock_register_handle "$o_locks/freshslug_crosslocked.json" term_stale_and_crosslocked
lock_merge_and_refresh "$o_locks/freshslug_crosslocked.json"

# freshslug_sidecar_only: registers a handle via the sidecar WITHOUT
# merging (no lock_merge_and_refresh call) — proving the sidecar itself,
# not just the merged "handles" array, is read when deciding protection
# (R2 finding). This handle is ALSO named by a separate stale lock.
lock_write "$o_locks/freshslug_sidecar_only.json" "$$" freshslug_sidecar_only 999999
lock_register_handle "$o_locks/freshslug_sidecar_only.json" term_sidecar_only_protected
lock_write "$o_locks/staleslug_sidecar.json" "$o_dead_pid" staleslug_sidecar 5
lock_register_handle "$o_locks/staleslug_sidecar.json" term_sidecar_only_protected
lock_merge_and_refresh "$o_locks/staleslug_sidecar.json"

# Push all the "stale" locks' heartbeats into the past, past their tiny
# ttlSeconds=5, without touching the fresh ones.
for _stale_lock in staleslug staleslug_alive_owner staleslug_crosslocked staleslug_sidecar; do
  python3 - "$o_locks/$_stale_lock.json" <<PY
import json, datetime
path = "$o_locks/$_stale_lock.json"
d = json.load(open(path))
d["heartbeatAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=999)).isoformat()
with open(path, "w") as f:
    json.dump(d, f)
PY
done
assert O0_stale_lock_is_stale "! lock_is_fresh \"$o_locks/staleslug.json\""
assert O0_fresh_lock_is_fresh "lock_is_fresh \"$o_locks/freshslug.json\""
assert O0_stale_alive_owner_is_stale "! lock_is_fresh \"$o_locks/staleslug_alive_owner.json\""
assert O0_dead_pid_is_dead "! kill -0 \"$o_dead_pid\" 2>/dev/null"
assert O0_test_pid_is_alive "kill -0 \"\$\$\""

python3 - "$o_journal" <<'PY'
import json, sys, datetime
path = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
old = (now - datetime.timedelta(seconds=5000)).isoformat()
young = now.isoformat()
rows = [
    # term_orphan_old: an EARLIER, since-replaced creation for debater_claude
    # that never became (or is no longer) the role's tracked handle — the
    # genuine bootstrap/recreate-style journal orphan. role kept non-null
    # here deliberately (matches a real create_role call); it is simply not
    # CURRENT any more, which is what "not in tracked" means in reality.
    {"role": "debater_claude", "title": "debate-opus", "raw": {}, "handle": "term_orphan_old", "createdAt": old},
    {"role": None, "title": "some-users-own-terminal", "raw": {}, "handle": "term_unrelated", "createdAt": old},
    # role=None here on purpose: this fixture's four tracked-debater role
    # slots are already used below (claude/codex/grok/gemini), and this
    # row's own test (O3, too-young) does not depend on role at all.
    {"role": None, "title": "debate-sol", "raw": {}, "handle": "term_too_young", "createdAt": young},
    {"role": "architect", "title": "role-opus-architect", "raw": {}, "handle": "term_tracked", "createdAt": old},
    {"role": "debater_grok", "title": "debate-grok", "raw": {}, "handle": None, "createdAt": old},
    # role=None: same reasoning as term_too_young above — O5 only needs
    # "claimed by a fresh lock", not "also currently tracked".
    {"role": None, "title": "debate-agy", "raw": {}, "handle": "term_protected", "createdAt": old},
    # The four debater handles below are each the CURRENT (and only) value
    # handles.json remembers for their role — exactly what handles_set
    # always leaves once ensure_terminal has succeeded, which is the
    # fixture realism review found missing. Each is deliberately placed in
    # a stale lock (see the lock_write calls above) so it is evaluated
    # ONLY by the stale-candidate path, isolating exactly what each new
    # check (owner-pid-alive / claimed-by-another-fresh-lock /
    # claimed-via-sidecar-only) is meant to test — none of them are
    # reachable via the tracked-check-gated journal-orphan path at all.
    {"role": "debater_claude", "title": "debate-opus", "raw": {}, "handle": "term_stale_candidate", "createdAt": old},
    {"role": "debater_codex", "title": "debate-sol", "raw": {}, "handle": "term_owner_still_alive", "createdAt": old},
    {"role": "debater_grok", "title": "debate-grok", "raw": {}, "handle": "term_stale_and_crosslocked", "createdAt": old},
    {"role": "debater_gemini", "title": "debate-agy", "raw": {}, "handle": "term_sidecar_only_protected", "createdAt": old},
]
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY

o_bin_live="$tmpdir/o-bin-live"
mkdir -p "$o_bin_live"
cat > "$o_bin_live/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list")
    echo '{"ok":true,"result":{"terminals":[
      {"handle":"term_orphan_old","connected":true},
      {"handle":"term_stale_candidate","connected":true},
      {"handle":"term_unrelated","connected":true},
      {"handle":"term_too_young","connected":true},
      {"handle":"term_tracked","connected":true},
      {"handle":"term_protected","connected":true},
      {"handle":"term_owner_still_alive","connected":true},
      {"handle":"term_stale_and_crosslocked","connected":true},
      {"handle":"term_sidecar_only_protected","connected":true}
    ]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$O_CLOSE_MARKER"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$o_bin_live/orca"

o_close_marker_a="$o_dir/closed-a.log"
: > "$o_close_marker_a"
o_rc_a=0
(
  export PATH="$o_bin_live:$PATH"
  export O_CLOSE_MARKER="$o_close_marker_a"
  "$SWEEP" --close --orch-dir "$o_orch" --journal "$o_journal" --handles-file "$o_handles" --locks-dir "$o_locks"
) >"$o_dir/sweep-a.out" 2>"$o_dir/sweep-a.err" || o_rc_a=$?
assert O1_run_exit_ok "[[ \"$o_rc_a\" -eq 0 ]]"
assert O1_closes_journal_orphan "grep -qx term_orphan_old \"$o_close_marker_a\""
assert O1_closes_stale_lock_handle_even_though_tracked_in_handles_json \
  "grep -qx term_stale_candidate \"$o_close_marker_a\""
assert O2_leaves_unrelated_title "! grep -qx term_unrelated \"$o_close_marker_a\""
assert O3_leaves_too_young "! grep -qx term_too_young \"$o_close_marker_a\""
assert O11_leaves_stale_lock_with_alive_owner "! grep -qx term_owner_still_alive \"$o_close_marker_a\""
assert O12_leaves_stale_and_crosslocked_handle "! grep -qx term_stale_and_crosslocked \"$o_close_marker_a\""
assert O13_leaves_sidecar_only_claimed_handle "! grep -qx term_sidecar_only_protected \"$o_close_marker_a\""
assert O4_leaves_tracked "! grep -qx term_tracked \"$o_close_marker_a\""
assert O5_leaves_lock_protected "! grep -qx term_protected \"$o_close_marker_a\""
assert O8_no_handle_reported "grep -q 'no-handle' \"$o_dir/sweep-a.out\""
assert O8_no_crash_on_no_handle "grep -qi 'unclosable' \"$o_dir/sweep-a.out\""

# Report-only (the sweeper's own default): the exact same candidates are
# identified, but nothing is actually closed without --close.
o_close_marker_default="$o_dir/closed-default.log"
: > "$o_close_marker_default"
o_rc_default=0
(
  export PATH="$o_bin_live:$PATH"
  export O_CLOSE_MARKER="$o_close_marker_default"
  "$SWEEP" --orch-dir "$o_orch" --journal "$o_journal" --handles-file "$o_handles" --locks-dir "$o_locks"
) >"$o_dir/sweep-default.out" 2>&1 || o_rc_default=$?
assert O6_default_run_exit_ok "[[ \"$o_rc_default\" -eq 0 ]]"
assert O6_default_report_only_no_close "[[ ! -s \"$o_close_marker_default\" ]]"
assert O6_default_reports_would_close "grep -q 'WOULD CLOSE' \"$o_dir/sweep-default.out\""

# --- O7: liveness undetermined (orca terminal list itself fails) — never
# act on ambiguity, no matter that --close was passed ---
o_bin_down="$tmpdir/o-bin-down"
mkdir -p "$o_bin_down"
cat > "$o_bin_down/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list") echo "simulated outage" >&2; exit 7 ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$O_CLOSE_MARKER"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$o_bin_down/orca"

o_close_marker_b="$o_dir/closed-b.log"
: > "$o_close_marker_b"
o_rc_b=0
(
  export PATH="$o_bin_down:$PATH"
  export O_CLOSE_MARKER="$o_close_marker_b"
  "$SWEEP" --close --orch-dir "$o_orch" --journal "$o_journal" --handles-file "$o_handles" --locks-dir "$o_locks"
) >"$o_dir/sweep-b.out" 2>"$o_dir/sweep-b.err" || o_rc_b=$?
assert O7_undetermined_run_exit_ok "[[ \"$o_rc_b\" -eq 0 ]]"
assert O7_undetermined_never_closes "[[ ! -s \"$o_close_marker_b\" ]]"
assert O7_undetermined_reported "grep -qi 'undetermined' \"$o_dir/sweep-b.out\""

# --- O9: a handles.json that EXISTS but fails to parse (handles_set writes
# it with a plain `open(path, "w")`, not an atomic temp-file-plus-rename, so
# a read can land mid-write; a hand-edited file can also break it) must
# abort the whole sweep rather than silently treat everything in it as
# untracked — the wrong fail-safe direction for a tool whose only job is
# never closing a terminal it does not own. Found by trying exactly this
# attack against the sweeper; see task-2-report.md. A missing handles.json
# (as opposed to present-but-broken) is deliberately NOT this case — T2's
# fixture setup above already exercises "missing" implicitly (O-series
# candidates close fine against the real $o_handles), so this specifically
# targets "present but corrupt."
o9_dir="$tmpdir/orphan-sweep-o9"
mkdir -p "$o9_dir/orch/debate-locks"
printf '{not valid json!!' > "$o9_dir/orch/handles.json"
cp "$o_journal" "$o9_dir/orch/terminal-journal.jsonl"
o9_close_marker="$o9_dir/closed.log"
: > "$o9_close_marker"
o9_rc=0
(
  export PATH="$o_bin_live:$PATH"
  export O_CLOSE_MARKER="$o9_close_marker"
  "$SWEEP" --close --orch-dir "$o9_dir/orch" --journal "$o9_dir/orch/terminal-journal.jsonl" \
    --handles-file "$o9_dir/orch/handles.json" --locks-dir "$o9_dir/orch/debate-locks"
) >"$o9_dir/sweep.out" 2>"$o9_dir/sweep.err" || o9_rc=$?
assert O9_malformed_handles_run_exit_ok "[[ \"$o9_rc\" -eq 0 ]]"
assert O9_malformed_handles_closes_nothing "[[ ! -s \"$o9_close_marker\" ]]"
assert O9_malformed_handles_reported "grep -qi 'could not be parsed' \"$o9_dir/sweep.err\""

# --- O10: a journal entry with role=null (exactly the Task 1
# bootstrap-partial-failure orphan this whole task exists to sweep — see
# orca-bootstrap-roles.sh's bare 2-arg create_role calls) still becomes a
# real candidate and gets closed, and the log line for it is not garbled.
# Regression for a real bug found while testing O9's ABORT path: bash
# classifies tab as an IFS "blank" character regardless of how IFS is set,
# so `IFS=$'\t' read` collapses a run of tabs — i.e. an EMPTY field (role
# is "" when the journal's role is null) between two adjacent delimiters —
# into a single delimiter instead of yielding an empty field, shifting
# every later field left by one. The handle/title fields (read before the
# empty one) were never affected, so the actual close decision was never
# wrong, but the printed reason text was silently swallowed. Fixed by never
# emitting a truly-empty TSV field (see field() in orca-sweep-orphans.sh).
o10_dir="$tmpdir/orphan-sweep-o10"
mkdir -p "$o10_dir/orch/debate-locks"
echo '{}' > "$o10_dir/orch/handles.json"
# Reuses the handle "term_orphan_old" (already known to o_bin_live's stub
# `orca terminal list` as connected) so this fixture does not need its own
# stub — only the role=null shape is new here. A second, too-young row
# (also role=null) proves a SKIP line's reason text — the field the
# collapsing bug actually swallowed externally-visibly — survives intact:
# a SKIP line for a normal (non-null-role) row already always worked, so
# this specifically targets the role="" case.
python3 - "$o10_dir/orch/terminal-journal.jsonl" <<'PY'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc)
rows = [
    {
        "role": None, "title": "debate-opus", "raw": {},
        "handle": "term_orphan_old",
        "createdAt": (now - datetime.timedelta(seconds=5000)).isoformat(),
    },
    {
        "role": None, "title": "debate-sol", "raw": {},
        "handle": "term_role_null_too_young",
        "createdAt": now.isoformat(),
    },
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
o10_close_marker="$o10_dir/closed.log"
: > "$o10_close_marker"
o10_rc=0
(
  export PATH="$o_bin_live:$PATH"
  export O_CLOSE_MARKER="$o10_close_marker"
  "$SWEEP" --close --orch-dir "$o10_dir/orch" --journal "$o10_dir/orch/terminal-journal.jsonl" \
    --handles-file "$o10_dir/orch/handles.json" --locks-dir "$o10_dir/orch/debate-locks"
) >"$o10_dir/sweep.out" 2>"$o10_dir/sweep.err" || o10_rc=$?
assert O10_role_null_run_exit_ok "[[ \"$o10_rc\" -eq 0 ]]"
assert O10_role_null_still_closed "grep -qx term_orphan_old \"$o10_close_marker\""
assert O10_role_null_skip_reason_not_swallowed \
  "grep -q 'term_role_null_too_young.*too young, guard against mid-creation race' \"$o10_dir/sweep.out\""

# ----------------------------------------------------------------------------
# P-series: --persist actually selects the STAY-OPEN tail (not AUTO-CLOSE),
# end-to-end through the real orca-dispatch-role.sh against a stubbed orca —
# not just at the dispatch_tail_block()/seed_text() function level (R3/R4
# above already cover those). Captures the exact --spec bytes handed to
# `orca orchestration task-create --json`.
# ----------------------------------------------------------------------------
persist_sandbox="$tmpdir/persist-sandbox/scripts"
mkdir -p "$persist_sandbox"
cp "$ROOT/scripts/orca-dispatch-role.sh" "$ROOT/scripts/orca-roles-lib.sh" "$persist_sandbox/"
echo '{}' > "$tmpdir/persist-sandbox/handles.json"
PERSIST_DISPATCH="$persist_sandbox/orca-dispatch-role.sh"

p_bin="$tmpdir/persist-bin"
mkdir -p "$p_bin"
cat > "$p_bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_persisttest"}}}' ;;
  "terminal rename") echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal send")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--text" ]]; then printf '%s' "$a" > "$P_MARKER_DIR/sent.txt"; fi
      prev="$a"
    done
    echo '{"ok":true,"result":{"send":{"handle":"term_persisttest","accepted":true}}}'
    ;;
  "terminal read") echo '{"ok":true,"result":{"terminal":{"handle":"term_persisttest","tail":["x"]}}}' ;;
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_persisttest","connected":true}]}}' ;;
  "orchestration task-create")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--spec" ]]; then printf '%s' "$a" > "$P_MARKER_DIR/spec.txt"; fi
      prev="$a"
    done
    echo '{"ok":true,"result":{"task":{"id":"task_persisttest"}}}'
    ;;
  "orchestration dispatch") echo '{"ok":true,"result":{"dispatch":{"id":"disp_persisttest"}}}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$p_bin/orca"

p_marker_1="$tmpdir/persist-marker-1"
mkdir -p "$p_marker_1"
p1_rc=0
(
  export PATH="$p_bin:$PATH"
  export P_MARKER_DIR="$p_marker_1"
  "$PERSIST_DISPATCH" debater_claude --persist --spec "irrelevant body one"
) >"$p_marker_1/persist.out" 2>"$p_marker_1/persist.err" || p1_rc=$?
assert P1_persist_dispatch_ok "[[ \"$p1_rc\" -eq 0 ]]"
assert P1_spec_has_stayopen "grep -q 'STAY-OPEN' \"$p_marker_1/spec.txt\""
assert P1_spec_no_close_cmd "! grep -q 'orca terminal close' \"$p_marker_1/spec.txt\""

p_marker_2="$tmpdir/persist-marker-2"
mkdir -p "$p_marker_2"
p2_rc=0
(
  export PATH="$p_bin:$PATH"
  export P_MARKER_DIR="$p_marker_2"
  "$PERSIST_DISPATCH" debater_claude --no-reap --spec "irrelevant body two"
) >"$p_marker_2/persist.out" 2>"$p_marker_2/persist.err" || p2_rc=$?
assert P2_autoclose_dispatch_ok "[[ \"$p2_rc\" -eq 0 ]]"
assert P2_spec_has_autoclose "grep -q 'AUTO-CLOSE' \"$p_marker_2/spec.txt\""
assert P2_spec_has_close_cmd "grep -q 'orca terminal close' \"$p_marker_2/spec.txt\""
assert P2_spec_no_stayopen "! grep -q 'STAY-OPEN' \"$p_marker_2/spec.txt\""

# --- P3: a --persist dispatch with an active lock context registers its
# handle (the wiring orca-debate.sh relies on to hand new debater handles to
# its own watchdog) ---
p3_lock_dir="$tmpdir/persist-lock"
mkdir -p "$p3_lock_dir"
P3_LOCK_FILE="$p3_lock_dir/p3slug.json"
lock_write "$P3_LOCK_FILE" "$$" p3slug 1800
p_marker_3="$tmpdir/persist-marker-3"
mkdir -p "$p_marker_3"
p3_rc=0
(
  export PATH="$p_bin:$PATH"
  export P_MARKER_DIR="$p_marker_3"
  export ORCA_ROLE_LOCK_FILE="$P3_LOCK_FILE"
  "$PERSIST_DISPATCH" debater_codex --persist --spec "irrelevant body three"
) >"$p_marker_3/persist.out" 2>"$p_marker_3/persist.err" || p3_rc=$?
lock_merge_and_refresh "$P3_LOCK_FILE"
assert P3_dispatch_ok "[[ \"$p3_rc\" -eq 0 ]]"
assert P3_handle_registered "lock_handles \"$P3_LOCK_FILE\" | grep -qx term_persisttest"

# A non-persist dispatch through the same lock context must NOT register
# anything (the PERSIST=1 gate is what keeps this feature debate-agnostic
# dispatch calls side-effect-free).
p3b_rc=0
(
  export PATH="$p_bin:$PATH"
  export P_MARKER_DIR="$p_marker_3"
  export ORCA_ROLE_LOCK_FILE="$P3_LOCK_FILE"
  "$PERSIST_DISPATCH" architect --no-reap --spec "irrelevant body four"
) >"$p_marker_3/persist-b.out" 2>"$p_marker_3/persist-b.err" || p3b_rc=$?
lock_merge_and_refresh "$P3_LOCK_FILE"
assert P3B_nonpersist_dispatch_ok "[[ \"$p3b_rc\" -eq 0 ]]"
assert P3B_nonpersist_not_registered "[[ \"\$(lock_handles \"$P3_LOCK_FILE\" | wc -l | tr -d ' ')\" == '1' ]]"

# ----------------------------------------------------------------------------
# W-series: the watchdog daemon itself. Real background processes (a fake
# "owner" and the real watchdog binary) against a stubbed orca — never the
# real Orca runtime. Every backgrounded pid goes into CLEANUP_PIDS.
# ----------------------------------------------------------------------------
w_dir="$tmpdir/watchdog"
mkdir -p "$w_dir/bin" "$w_dir/locks"
export W_CLOSE_MARKER="$w_dir/closed.log"
: > "$W_CLOSE_MARKER"
cat > "$w_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list")
    echo '{"ok":true,"result":{"terminals":[{"handle":"term_w_owned","connected":true},{"handle":"term_w_shared","connected":true}]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$W_CLOSE_MARKER"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$w_dir/bin/orca"

wait_for() {
  # $1=timeout_ms $2=condition-as-eval-string. Short, bounded polling for an
  # async background process to reach an observable state — the same idiom
  # F5 above already uses (poll the driver's own log for proof round 1 is in
  # flight) rather than a long fixed sleep.
  local timeout_ms="$1" cond="$2" waited=0
  while [[ "$waited" -lt "$timeout_ms" ]]; do
    if eval "$cond"; then return 0; fi
    sleep 0.1
    waited=$((waited + 100))
  done
  return 1
}

# --- W1: a normal stop (debate_watchdog_start/stop, the exact pair
# orca-debate.sh calls) leaves no watchdog process running and never
# touches the owned handle. ---
sleep 300 & w1_owner_pid=$!
CLEANUP_PIDS+=("$w1_owner_pid")
w1_lock_file="$w_dir/locks/w1slug.json"
w1_pidfile="$w_dir/locks/w1slug.watchdog.pid"

OLD_PATH="$PATH"
export PATH="$w_dir/bin:$PATH"
w1_wpid="$(debate_watchdog_start "$ROOT/scripts" "$w1_lock_file" w1slug "$w1_owner_pid" "$w_dir/locks" 1800)"
export PATH="$OLD_PATH"
printf '%s\n' "$w1_wpid" > "$w1_pidfile"
CLEANUP_PIDS+=("$w1_wpid")

w1_up=0
wait_for 2000 "kill -0 $w1_wpid 2>/dev/null" && w1_up=1
assert W1_watchdog_started "[[ \"$w1_up\" -eq 1 ]]"
assert W1_lock_created "[[ -f \"$w1_lock_file\" ]]"

# Wait for proof the watchdog has cleared its (slow — sourcing a library,
# parsing args) startup and reached its steady-state poll loop, THEN give
# it a beat more to clear one loop iteration's synchronous work (pid
# compare, kill -0, lock_merge_and_refresh) and actually enter its sleep.
# Without this, debate_watchdog_stop's lock_remove can race the watchdog's
# own still-starting-up first loop check and let it exit via "lock file
# gone" instead of via the SIGTERM this block exists to test — a real gap
# found empirically: an earlier draft of this test called
# debate_watchdog_stop immediately after fork, and a mutation that
# disabled SIGTERM entirely still passed, because the lock-file-gone path
# papered over it.
wait_for 3000 "grep -q 'watching owner pid=' \"${w1_lock_file%.json}.watchdog.log\" 2>/dev/null" || true
sleep 1

debate_watchdog_stop "$w1_pidfile" "$w1_lock_file"

# A working SIGTERM handler exits promptly — bounded to roughly
# sleep_interruptible's 1s chunk size (see orca-sweep-orphans.sh), not the
# full ~20s poll interval. This bound is only reliable BECAUSE of
# sleep_interruptible: confirmed empirically on this repo's bash (3.2.57)
# that a trap on a signal already registered does NOT preempt a
# currently-running external `sleep N` — it only runs once that sleep
# returns on its own. A single `sleep "$POLL_SECONDS"` here would have made
# a normal stop take up to the full poll interval (still eventually
# correct, just not prompt) and would have made this assertion's 3s window
# see the watchdog as still alive, a false failure unrelated to whether
# SIGTERM actually works. Deliberately tight enough (3s) that a regression
# (SIGTERM silently not delivered, or the sleep un-chunked again) shows up
# as this assertion failing, not as a slow-but-eventually-green test.
w1_stopped=0
wait_for 3000 "! kill -0 $w1_wpid 2>/dev/null" && w1_stopped=1
assert W1_watchdog_stopped "[[ \"$w1_stopped\" -eq 1 ]]"
assert W1_lock_removed "[[ ! -f \"$w1_lock_file\" ]]"
assert W1_pidfile_removed "[[ ! -f \"$w1_pidfile\" ]]"
assert W1_close_marker_empty "[[ ! -s \"$W_CLOSE_MARKER\" ]]"

kill -9 "$w1_owner_pid" 2>/dev/null || true

# --- W2: kill -9 on the owner — THE most important criterion. The
# watchdog (a genuinely separate process, never a child kept alive by the
# owner) notices via its own polling and closes the owned handle, well
# within the poll interval and nowhere near the full TTL. ---
: > "$W_CLOSE_MARKER"
sleep 300 & w2_owner_pid=$!
CLEANUP_PIDS+=("$w2_owner_pid")

w2_lock_file="$w_dir/locks/w2slug.json"
lock_write "$w2_lock_file" "$w2_owner_pid" w2slug 1800
lock_register_handle "$w2_lock_file" term_w_owned
lock_merge_and_refresh "$w2_lock_file"

OLD_PATH="$PATH"
export PATH="$w_dir/bin:$PATH"
"$SWEEP" --watchdog --slug w2slug --owner-pid "$w2_owner_pid" --locks-dir "$w_dir/locks" \
  --poll-seconds 1 --max-close-attempts 3 >"$w_dir/w2-watchdog.log" 2>&1 &
w2_watchdog_pid=$!
export PATH="$OLD_PATH"
CLEANUP_PIDS+=("$w2_watchdog_pid")

wait_for 3000 "kill -0 $w2_watchdog_pid 2>/dev/null" || true

echo "=== W2 kill -9 demonstration: owner pid=$w2_owner_pid, watchdog pid=$w2_watchdog_pid ==="
kill -9 "$w2_owner_pid"

w2_closed=0
wait_for 8000 "grep -qx term_w_owned \"$W_CLOSE_MARKER\" 2>/dev/null" && w2_closed=1
assert W2_kill9_closes_owned_handle "[[ \"$w2_closed\" -eq 1 ]]"

w2_gone=0
wait_for 3000 "! kill -0 $w2_watchdog_pid 2>/dev/null" && w2_gone=1
assert W2_watchdog_process_exits_after "[[ \"$w2_gone\" -eq 1 ]]"
assert W2_lock_removed_after_close "[[ ! -f \"$w2_lock_file\" ]]"

echo "--- W2 watchdog log ---"
cat "$w_dir/w2-watchdog.log" 2>/dev/null || true
echo "--- end W2 watchdog log ---"

# --- W3: a lock whose owning pid changes underneath a running watchdog
# (e.g. a second driver reusing the same slug) makes it stand down without
# ever touching a handle — it must never assume ownership it was not given. ---
: > "$W_CLOSE_MARKER"
sleep 300 & w3_orig_owner_pid=$!
CLEANUP_PIDS+=("$w3_orig_owner_pid")
sleep 300 & w3_new_owner_pid=$!
CLEANUP_PIDS+=("$w3_new_owner_pid")

w3_lock_file="$w_dir/locks/w3slug.json"
lock_write "$w3_lock_file" "$w3_orig_owner_pid" w3slug 1800
lock_register_handle "$w3_lock_file" term_w_owned
lock_merge_and_refresh "$w3_lock_file"

OLD_PATH="$PATH"
export PATH="$w_dir/bin:$PATH"
"$SWEEP" --watchdog --slug w3slug --owner-pid "$w3_orig_owner_pid" --locks-dir "$w_dir/locks" \
  --poll-seconds 1 >"$w_dir/w3-watchdog.log" 2>&1 &
w3_watchdog_pid=$!
export PATH="$OLD_PATH"
CLEANUP_PIDS+=("$w3_watchdog_pid")

wait_for 3000 "kill -0 $w3_watchdog_pid 2>/dev/null" || true
# simulate a second driver taking over the same slug
lock_write "$w3_lock_file" "$w3_new_owner_pid" w3slug 1800

w3_stood_down=0
wait_for 5000 "! kill -0 $w3_watchdog_pid 2>/dev/null" && w3_stood_down=1
assert W3_watchdog_stands_down "[[ \"$w3_stood_down\" -eq 1 ]]"
assert W3_no_close_attempted "[[ ! -s \"$W_CLOSE_MARKER\" ]]"

kill -9 "$w3_orig_owner_pid" 2>/dev/null || true
kill -9 "$w3_new_owner_pid" 2>/dev/null || true

# --- W4: two locks legitimately share a handle (ensure_terminal reuses a
# live role terminal globally, so two different debates can end up
# dispatching to, and each registering, the SAME underlying handle). Lock
# A's owner dies; lock B's owner stays alive and fresh throughout. Lock A's
# watchdog must NOT close the handle a different, still-live debate (lock
# B) is actively depending on. ---
: > "$W_CLOSE_MARKER"
sleep 300 & w4a_owner_pid=$!
CLEANUP_PIDS+=("$w4a_owner_pid")
sleep 300 & w4b_owner_pid=$!
CLEANUP_PIDS+=("$w4b_owner_pid")

w4a_lock_file="$w_dir/locks/w4a.json"
w4b_lock_file="$w_dir/locks/w4b.json"
lock_write "$w4a_lock_file" "$w4a_owner_pid" w4a 1800
lock_register_handle "$w4a_lock_file" term_w_shared
lock_merge_and_refresh "$w4a_lock_file"
lock_write "$w4b_lock_file" "$w4b_owner_pid" w4b 1800
lock_register_handle "$w4b_lock_file" term_w_shared
lock_merge_and_refresh "$w4b_lock_file"

OLD_PATH="$PATH"
export PATH="$w_dir/bin:$PATH"
"$SWEEP" --watchdog --slug w4a --owner-pid "$w4a_owner_pid" --locks-dir "$w_dir/locks" \
  --poll-seconds 1 --max-close-attempts 3 >"$w_dir/w4-watchdog.log" 2>&1 &
w4_watchdog_pid=$!
export PATH="$OLD_PATH"
CLEANUP_PIDS+=("$w4_watchdog_pid")

wait_for 3000 "kill -0 $w4_watchdog_pid 2>/dev/null" || true
kill -9 "$w4a_owner_pid"

w4_watchdog_gone=0
wait_for 6000 "! kill -0 $w4_watchdog_pid 2>/dev/null" && w4_watchdog_gone=1
assert W4_watchdog_a_exits "[[ \"$w4_watchdog_gone\" -eq 1 ]]"
assert W4_shared_handle_not_closed "! grep -qx term_w_shared \"$W_CLOSE_MARKER\""
assert W4_lock_a_removed "[[ ! -f \"$w4a_lock_file\" ]]"
assert W4_lock_b_untouched "[[ -f \"$w4b_lock_file\" ]]"

kill -9 "$w4b_owner_pid" 2>/dev/null || true

# --- W5: two locks share a handle and BOTH owners die (near-simultaneously,
# so both locks' heartbeats stay well within their 1800s TTL throughout —
# they are indistinguishable from "fresh" by heartbeat alone). This is the
# mutual-deference trap found in review: a freshness-only cross-lock check
# would let EACH watchdog defer to the other (both would see the other
# lock as still "fresh" and stand down, satisfied someone else has it) and
# the handle would never be closed by either — the exact permanently-
# orphaned, permission-bypassed terminal this feature exists to prevent.
# Requiring the OTHER lock's owner to be a CONFIRMED-ALIVE pid (not
# freshness alone) breaks the deadlock: once both owners are dead, neither
# watchdog defers, and the handle gets closed. ---
: > "$W_CLOSE_MARKER"
sleep 300 & w5a_owner_pid=$!
CLEANUP_PIDS+=("$w5a_owner_pid")
sleep 300 & w5b_owner_pid=$!
CLEANUP_PIDS+=("$w5b_owner_pid")

w5a_lock_file="$w_dir/locks/w5a.json"
w5b_lock_file="$w_dir/locks/w5b.json"
lock_write "$w5a_lock_file" "$w5a_owner_pid" w5a 1800
lock_register_handle "$w5a_lock_file" term_w_shared
lock_merge_and_refresh "$w5a_lock_file"
lock_write "$w5b_lock_file" "$w5b_owner_pid" w5b 1800
lock_register_handle "$w5b_lock_file" term_w_shared
lock_merge_and_refresh "$w5b_lock_file"

OLD_PATH="$PATH"
export PATH="$w_dir/bin:$PATH"
"$SWEEP" --watchdog --slug w5a --owner-pid "$w5a_owner_pid" --locks-dir "$w_dir/locks" \
  --poll-seconds 1 --max-close-attempts 3 >"$w_dir/w5a-watchdog.log" 2>&1 &
w5a_watchdog_pid=$!
"$SWEEP" --watchdog --slug w5b --owner-pid "$w5b_owner_pid" --locks-dir "$w_dir/locks" \
  --poll-seconds 1 --max-close-attempts 3 >"$w_dir/w5b-watchdog.log" 2>&1 &
w5b_watchdog_pid=$!
export PATH="$OLD_PATH"
CLEANUP_PIDS+=("$w5a_watchdog_pid" "$w5b_watchdog_pid")

wait_for 3000 "kill -0 $w5a_watchdog_pid 2>/dev/null && kill -0 $w5b_watchdog_pid 2>/dev/null" || true
kill -9 "$w5a_owner_pid"
kill -9 "$w5b_owner_pid"

w5_closed=0
wait_for 8000 "grep -qx term_w_shared \"$W_CLOSE_MARKER\" 2>/dev/null" && w5_closed=1
assert W5_mutual_deference_still_closes "[[ \"$w5_closed\" -eq 1 ]]"

w5a_gone=0
wait_for 5000 "! kill -0 $w5a_watchdog_pid 2>/dev/null" && w5a_gone=1
assert W5_watchdog_a_exits "[[ \"$w5a_gone\" -eq 1 ]]"
w5b_gone=0
wait_for 5000 "! kill -0 $w5b_watchdog_pid 2>/dev/null" && w5b_gone=1
assert W5_watchdog_b_exits "[[ \"$w5b_gone\" -eq 1 ]]"

# --- W6: deadlock matrix, third case — two locks share a handle and BOTH
# owners stay alive throughout. Neither watchdog ever has a reason to enter
# its close phase (their own kill -0 on their own owner keeps succeeding),
# so nothing should be closed and both watchdogs should still be quietly
# running at the end. Completes the matrix the C1–C3 function-level tests
# and W4 (one alive)/W5 (both dead) already cover at the watchdog level. ---
: > "$W_CLOSE_MARKER"
sleep 300 & w6a_owner_pid=$!
CLEANUP_PIDS+=("$w6a_owner_pid")
sleep 300 & w6b_owner_pid=$!
CLEANUP_PIDS+=("$w6b_owner_pid")

w6a_lock_file="$w_dir/locks/w6a.json"
w6b_lock_file="$w_dir/locks/w6b.json"
lock_write "$w6a_lock_file" "$w6a_owner_pid" w6a 1800
lock_register_handle "$w6a_lock_file" term_w_shared
lock_merge_and_refresh "$w6a_lock_file"
lock_write "$w6b_lock_file" "$w6b_owner_pid" w6b 1800
lock_register_handle "$w6b_lock_file" term_w_shared
lock_merge_and_refresh "$w6b_lock_file"

OLD_PATH="$PATH"
export PATH="$w_dir/bin:$PATH"
"$SWEEP" --watchdog --slug w6a --owner-pid "$w6a_owner_pid" --locks-dir "$w_dir/locks" \
  --poll-seconds 1 >"$w_dir/w6-watchdog.log" 2>&1 &
w6_watchdog_pid=$!
export PATH="$OLD_PATH"
CLEANUP_PIDS+=("$w6_watchdog_pid")

wait_for 3000 "kill -0 $w6_watchdog_pid 2>/dev/null" || true
sleep 3
assert W6_both_alive_watchdog_still_running "kill -0 $w6_watchdog_pid 2>/dev/null"
assert W6_both_alive_nothing_closed "[[ ! -s \"$W_CLOSE_MARKER\" ]]"
assert W6_both_alive_lock_a_intact "[[ -f \"$w6a_lock_file\" ]]"

kill -9 "$w6a_owner_pid" 2>/dev/null || true
kill -9 "$w6b_owner_pid" 2>/dev/null || true
kill -9 "$w6_watchdog_pid" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Q-series: the REAL orca-debate.sh's watchdog wiring — lock path
# construction, the debate_watchdog_start call, cleanup()'s ordering. Every
# other driver test in this file uses --dry-run, which skips watchdog
# creation entirely, so none of them exercise this ~15-line integration
# block; the W-series above calls library functions directly (or a
# hand-built substitute), not the real script. This runs the ACTUAL
# orca-debate.sh (copied into an isolated sandbox — never the real
# project's .orca/ state), with dispatch replaced via this suite's existing
# ORCA_TEST_DISPATCH seam (so no real terminal ever gets created) but the
# lock/watchdog machinery fully real.
# ----------------------------------------------------------------------------
q_root="$tmpdir/driver-sandbox"
q_scripts="$q_root/scripts"
mkdir -p "$q_scripts"
cp "$ROOT/scripts/orca-debate.sh" "$ROOT/scripts/orca-debate-round.sh" "$ROOT/scripts/orca-debate-lib.sh" \
   "$ROOT/scripts/orca-roles-lib.sh" "$ROOT/scripts/orca-sweep-orphans.sh" "$ROOT/scripts/orca-close-role.sh" \
   "$q_scripts/"
Q_DRIVER="$q_scripts/orca-debate.sh"
Q_LOCKS_DIR="$q_root/debate-locks"

q_bin="$tmpdir/q-bin"
mkdir -p "$q_bin"
cat > "$q_bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "status --json") echo '{"ok":true,"reachable": true}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$q_bin/orca"
# Stub the debater CLIs themselves so preflight's `command -v` checks are
# deterministic rather than depending on what happens to be installed on
# the machine running this suite (a real, pre-existing gap the F-series
# driver tests above already silently rely on; this test does not need to
# inherit it).
for _q_cli in claude codex grok agy; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$q_bin/$_q_cli"
  chmod +x "$q_bin/$_q_cli"
done

q_stub_dir="$tmpdir/q-stub"
mkdir -p "$q_stub_dir"
q_dispatch_log="$tmpdir/q-dispatch.log"
: > "$q_dispatch_log"
cat > "$q_stub_dir/orca-dispatch-role.sh" <<SH
#!/usr/bin/env bash
role="\$1"; shift
spec=""
persist=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --spec) spec="\$2"; shift 2 ;;
    --persist) persist=1; shift ;;
    *) shift ;;
  esac
done
target="\$(printf '%s' "\$spec" | grep -m1 -o '/[^ ]*/round-[0-9]*/[a-z]*\.md')"
mkdir -p "\$(dirname "\$target")"
{
  echo "# stub"
  echo "## Prior art"
  echo "## Proposals"
  echo "- Weakest link: stub"
  echo "## Directions I deliberately rejected"
} > "\$target"
echo "STUB_DISPATCH role=\$role persist=\$persist lockfile=\${ORCA_ROLE_LOCK_FILE:-<unset>}" >> "$q_dispatch_log"
echo "task_id=task_\${role}"
SH
chmod +x "$q_stub_dir/orca-dispatch-role.sh"

q_debates_dir="$q_root/debates"
Q_OLD_PATH="$PATH"
export PATH="$q_bin:$PATH"
export ORCA_TEST_DISPATCH="$q_stub_dir/orca-dispatch-role.sh"
export ORCA_TEST_STATUS_STUB=completed
"$Q_DRIVER" --topic "watchdog wiring test" --slug qwiring --rounds 1 --dir-root "$q_debates_dir" \
  --lock-ttl-seconds 1800 >"$q_root/driver.out" 2>"$q_root/driver.err" &
q_driver_pid=$!
export PATH="$Q_OLD_PATH"
unset ORCA_TEST_DISPATCH ORCA_TEST_STATUS_STUB
CLEANUP_PIDS+=("$q_driver_pid")

# Grab the watchdog's own pid WHILE the driver is still running — cleanup()
# removes its pidfile on normal exit, so it must be captured before that.
q_watchdog_pidfile="$Q_LOCKS_DIR/qwiring.watchdog.pid"
wait_for 5000 "[[ -f \"$q_watchdog_pidfile\" ]]" || true
q_watchdog_pid="$(cat "$q_watchdog_pidfile" 2>/dev/null || true)"
[[ -n "$q_watchdog_pid" ]] && CLEANUP_PIDS+=("$q_watchdog_pid")

q_rc=0
wait "$q_driver_pid" || q_rc=$?

assert Q1_driver_exits_ok "[[ \"$q_rc\" -eq 0 ]]"
assert Q2_watchdog_pid_was_captured "[[ -n \"$q_watchdog_pid\" ]]"
assert Q3_watchdog_log_shows_real_driver_pid \
  "grep -q \"watching owner pid=$q_driver_pid\" \"$Q_LOCKS_DIR/qwiring.watchdog.log\""
assert Q4_lock_removed_by_real_cleanup "[[ ! -f \"$Q_LOCKS_DIR/qwiring.json\" ]]"
assert Q5_pidfile_removed_by_real_cleanup "[[ ! -f \"$q_watchdog_pidfile\" ]]"

q_watchdog_gone=0
wait_for 3000 "! kill -0 $q_watchdog_pid 2>/dev/null" && q_watchdog_gone=1
assert Q6_watchdog_process_exits_after_normal_run "[[ \"$q_watchdog_gone\" -eq 1 ]]"

# Proves the ORCA_ROLE_LOCK_FILE export (orca-debate.sh) actually reaches a
# --persist dispatch child process, not just that the driver believes it
# set it — nothing else in this suite exercises that specific env-var
# hand-off through the real script (P3 covers the registration behavior
# itself, directly, without going through orca-debate.sh).
assert Q7_dispatch_saw_persist "grep -q 'persist=1' \"$q_dispatch_log\""
assert Q8_dispatch_saw_real_lock_file "! grep -q 'lockfile=<unset>' \"$q_dispatch_log\""
assert Q8_dispatch_lock_file_matches "grep -q \"lockfile=$Q_LOCKS_DIR/qwiring.json\" \"$q_dispatch_log\""

echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" -gt 0 ]] && exit 1
exit 0
