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
ORCA_DEBATE_DISPATCH="$STUB/orca-dispatch-role.sh" \
ORCA_DEBATE_STATUS_STUB=completed \
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
if ORCA_DEBATE_DISPATCH="$STUB/orca-dispatch-role.sh" \
   ORCA_DEBATE_STATUS_STUB=failed \
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
ORCA_DEBATE_DISPATCH="$STUB/orca-dispatch-role-fail1.sh" \
ORCA_DEBATE_STATUS_STUB=completed \
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

echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" -gt 0 ]] && exit 1
exit 0
