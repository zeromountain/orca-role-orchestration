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

# --- D3 label map (Task 3: debate_label_map_ensure — driver-only, shuffled,
# roster-checked; replaces the old positional debate_label_map_create). ---
MAP="$tmpdir/labels/test-slug.json"
map_json="$(debate_label_map_ensure "$MAP" test-slug "claude,codex,grok,gemini")"
assert D3_file "[[ -f \"$MAP\" ]]"
assert D3_schema_slug \
  "printf '%s' \"\$map_json\" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"slug\"]==\"test-slug\" else 1)'"
assert D3_schema_roster \
  "printf '%s' \"\$map_json\" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if sorted(d[\"roster\"])==[\"claude\",\"codex\",\"gemini\",\"grok\"] else 1)'"
assert D3_all_four_labeled \
  "[[ -n \"\$(debate_label_of \"$MAP\" claude)\" && -n \"\$(debate_label_of \"$MAP\" codex)\" && -n \"\$(debate_label_of \"$MAP\" grok)\" && -n \"\$(debate_label_of \"$MAP\" gemini)\" ]]"
assert D3_unknown_short_is_empty "[[ -z \"\$(debate_label_of \"$MAP\" nobody)\" ]]"

# Stable across a re-call with the SAME roster (even reordered CSV) — this is
# what lets round 1/2/3 (each a SEPARATE orca-debate-round.sh process) agree
# on what "Proposal C" means without re-shuffling mid-debate.
claude_label_before="$(debate_label_of "$MAP" claude)"
debate_label_map_ensure "$MAP" test-slug "gemini,grok,codex,claude" >/dev/null
assert D3_stable_same_roster "[[ \"\$(debate_label_of \"$MAP\" claude)\" == \"$claude_label_before\" ]]"

# --- D3-mismatch: a re-run with a CHANGED roster must not silently reuse the
# stale map (Step 4) — it must rebuild (fresh shuffle for the new roster) and
# say so loudly, dropping the departed member's label (no ghost) while every
# current member still gets a real one (no silent gap). ---
mismatch_err="$(debate_label_map_ensure "$MAP" test-slug "claude,codex,grok" 2>&1 >/dev/null)"
assert D3m_warns_not_silent "printf '%s' \"\$mismatch_err\" | grep -qi 'roster changed'"
assert D3m_drops_departed_gemini "[[ -z \"\$(debate_label_of \"$MAP\" gemini)\" ]]"
assert D3m_keeps_claude_labeled "[[ -n \"\$(debate_label_of \"$MAP\" claude)\" ]]"
assert D3m_roster_field_updated \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sorted(d[\"roster\"])==[\"claude\",\"codex\",\"grok\"] else 1)' \"$MAP\""

# --- D3-shuffle: labels are SHUFFLED per debate, not positional from CSV
# order (the historical bug: A was always whatever came first in
# --debaters). Every iteration below uses a FRESH, never-before-created map
# path (a distinct slug each time) — debate_label_map_ensure only shuffles on
# CREATION, so reusing one path across iterations would just test the
# already-covered stability path instead. With 4 debaters there are only 24
# possible assignments, so seeing more than one distinct assignment across
# 15 independent fresh runs — or claude landing on anything other than "A"
# even once — all but rules out a fixed/positional scheme, which would
# produce the IDENTICAL assignment (claude=A always) every single time.
shuffle_dir="$tmpdir/shuffle-evidence"
mkdir -p "$shuffle_dir"
first_assignment=""
saw_a_difference=0
saw_claude_non_a=0
for shuffle_i in $(seq 1 15); do
  sfile="$shuffle_dir/run-$shuffle_i.json"
  debate_label_map_ensure "$sfile" "shuffle-slug-$shuffle_i" "claude,codex,grok,gemini" >/dev/null
  this_assignment="$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(",".join(d["labels"][k] for k in ["claude", "codex", "grok", "gemini"]))' "$sfile")"
  if [[ -z "$first_assignment" ]]; then
    first_assignment="$this_assignment"
  elif [[ "$this_assignment" != "$first_assignment" ]]; then
    saw_a_difference=1
  fi
  [[ "$(debate_label_of "$sfile" claude)" != "A" ]] && saw_claude_non_a=1
done
assert D3s_shuffled_across_runs "[[ \"$saw_a_difference\" -eq 1 ]]"
assert D3s_claude_not_pinned_to_seat_a "[[ \"$saw_claude_non_a\" -eq 1 ]]"

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
# $out paths below are label-shaped (single uppercase letter), matching what
# orca-debate-round.sh now actually builds ($ROUND_DIR/$own.md) — this is
# what Steps 1 and 3 require: a debater told to read round-(N-1)/*.md, or its
# own round-1/<label>.md, must never see a model-named path or filename.
TOPIC="$tmpdir/topic.md"
printf 'TOPIC_MARKER\n' > "$TOPIC"
S1="$(debate_spec propose claude "$tmpdir" 1 "$tmpdir/round-1/A.md" A "$TOPIC")"
assert D7_propose_topic  "printf '%s' \"\$S1\" | grep -q TOPIC_MARKER"
assert D7_propose_out    "printf '%s' \"\$S1\" | grep -q 'round-1/A.md'"
assert D7_propose_head   "printf '%s' \"\$S1\" | grep -q '## Prior art'"
assert D7_propose_source "printf '%s' \"\$S1\" | grep -q '미검증'"
assert D7_propose_ro     "printf '%s' \"\$S1\" | grep -q 'Never run git commit'"
S2="$(debate_spec critique codex "$tmpdir" 2 "$tmpdir/round-2/B.md" B "$TOPIC")"
# Defect 1 fixed: critique now reads the PREVIOUS round's own directory
# (round-1/*.md — every file in it is already label-named), not a copy
# stashed under round-2/proposal-*.md.
assert D7_crit_paths "printf '%s' \"\$S2\" | grep -qF 'round-1/*.md'"
assert D7_crit_own   "printf '%s' \"\$S2\" | grep -q 'Proposal B is your own'"
assert D7_crit_head  "printf '%s' \"\$S2\" | grep -q '## Ranking'"
assert D7_crit_no_model_name "! printf '%s' \"\$S2\" | grep -qiE 'claude|codex|grok|gemini'"
S3="$(debate_spec converge grok "$tmpdir" 3 "$tmpdir/round-3/C.md" C "$TOPIC")"
# Defect 3 fixed: converge points a debater at its OWN round-1 file by LABEL
# (round-1/<own-label>.md), never by short/model name (the literal
# round-1/<short>.md leak this replaces).
assert D7_conv_paths     "printf '%s' \"\$S3\" | grep -qF 'round-2/*.md'"
assert D7_conv_own_path  "printf '%s' \"\$S3\" | grep -qF 'round-1/C.md'"
assert D7_conv_head      "printf '%s' \"\$S3\" | grep -q '## Dissent'"
assert D7_conv_no_model_name "! printf '%s' \"\$S3\" | grep -qiE 'claude|codex|grok|gemini'"

# --- E1 round script dry-run (no Orca runtime touched) ---
ROUND="$ROOT/scripts/orca-debate-round.sh"
DEB="$tmpdir/debate"
mkdir -p "$DEB"
printf 'TOPIC_E1\n' > "$DEB/topic.md"
E1_LABEL_MAP="$tmpdir/e1-no-such-label-map.json"   # deliberately never created

assert E1_exec "[[ -x \"$ROUND\" ]]"
assert E1_needs_args "! \"$ROUND\" >/dev/null 2>&1"
# --label-map is now a required flag (Task 3) — omitting it entirely must be
# a usage error, same as omitting --dir/--round/--phase.
assert E1_requires_label_map \
  "! \"$ROUND\" --dir \"$DEB\" --round 1 --phase propose --dry-run >/dev/null 2>&1"

# A --dry-run preview tolerates a label map that does not exist at all (own
# label falls back to "?" — see orca-debate-round.sh) since nothing is
# actually dispatched; this also proves a bare preview invocation (no driver,
# no real map) still works.
OUT="$("$ROUND" --dir "$DEB" --round 1 --phase propose --label-map "$E1_LABEL_MAP" --dry-run 2>&1)"
assert E1_dry_four   "[[ \"\$(printf '%s' \"\$OUT\" | grep -c '^===== debater_')\" == '4' ]]"
assert E1_dry_topic  "printf '%s' \"\$OUT\" | grep -q TOPIC_E1"
assert E1_dry_nodisp "! printf '%s' \"\$OUT\" | grep -q 'Creating task'"
assert E1_dry_subset "[[ \"\$(\"$ROUND\" --dir \"$DEB\" --round 1 --phase propose --debaters claude,grok --label-map \"$E1_LABEL_MAP\" --dry-run 2>&1 | grep -c '^===== debater_')\" == '2' ]]"

# --- E2 collection + quorum, with dispatch and polling stubbed ---
STUB="$tmpdir/stubbin"
mkdir -p "$STUB"
cat > "$STUB/orca-dispatch-role.sh" <<'SH'
#!/usr/bin/env bash
# stub: echo a task id, write the debater's output file from the spec's target
# path. The target is extracted from the exact "- Write your answer ONLY to
# this file: <path>" line (debate_common_rules) — this is what makes the stub
# use the path debate_spec/orca-debate-round.sh ACTUALLY told it to write to,
# rather than a path the stub invented itself; a stub that computed its own
# label-to-path mapping independently could pass even if the real code
# regressed to short-name paths. A cruder "any /round-N/<label>.md-shaped
# substring" extraction is NOT equivalent and was tried first: the converge
# phase's own spec text also contains "Your own round-1 proposal is at:
# .../round-1/<label>.md" BEFORE the real output-file line, so a first-match
# extraction silently grabs the wrong path for that phase (own round-1
# self-reference instead of round-N's actual output) — found by this task's
# own self-review, not by a failing assertion; see task-3-report.md.
role="$1"; shift
spec=""
while [[ $# -gt 0 ]]; do
  case "$1" in --spec) spec="$2"; shift 2 ;; *) shift ;; esac
done
target="$(printf '%s' "$spec" | sed -n 's/.*this file: //p' | head -1)"
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
E2_LABEL_MAP="$tmpdir/labels-e2.json"
E2_MANIFEST="$tmpdir/manifests-e2/round-1.json"
# The label map is created here exactly as orca-debate.sh (the driver) would
# — this script never creates its own (Task 3: only the driver owns it).
debate_label_map_ensure "$E2_LABEL_MAP" e2slug "claude,codex,grok,gemini" >/dev/null
ORCA_TEST_DISPATCH="$STUB/orca-dispatch-role.sh" \
ORCA_TEST_STATUS_STUB=completed \
"$ROUND" --dir "$DEB2" --round 1 --phase propose --timeout-ms 5000 \
  --label-map "$E2_LABEL_MAP" --manifest "$E2_MANIFEST" >/dev/null 2>&1
e2_claude_label="$(debate_label_of "$E2_LABEL_MAP" claude)"
e2_gemini_label="$(debate_label_of "$E2_LABEL_MAP" gemini)"
assert E2_files "[[ -f \"$DEB2/round-1/$e2_claude_label.md\" && -f \"$DEB2/round-1/$e2_gemini_label.md\" ]]"
assert E2_manifest_outside_debate_dir "[[ -f \"$E2_MANIFEST\" ]]"
assert E2_manifest_not_in_debate_dir "[[ ! -f \"$DEB2/round-1/manifest.json\" ]]"
assert E2_manifest_has_real_name "grep -q '\"debater\": \"claude\"' \"$E2_MANIFEST\""
assert E2_no_copies_written "[[ ! -d \"$DEB2/round-2\" ]]"
assert E2_label_map_not_in_debate_dir "[[ ! -f \"$DEB2/round-1/label-map.json\" && ! -f \"$DEB2/round-2/label-map.json\" ]]"

# quorum failure: stub reports failed for everyone
DEB3="$tmpdir/debate3"
mkdir -p "$DEB3"
printf 'TOPIC_E3\n' > "$DEB3/topic.md"
E3_LABEL_MAP="$tmpdir/labels-e3.json"
debate_label_map_ensure "$E3_LABEL_MAP" e3slug "claude,codex,grok,gemini" >/dev/null
# The round script exits 2 here by design, so the call must be if-guarded:
# tests/debate.sh runs under `set -e`, which would otherwise abort the suite.
if ORCA_TEST_DISPATCH="$STUB/orca-dispatch-role.sh" \
   ORCA_TEST_STATUS_STUB=failed \
   "$ROUND" --dir "$DEB3" --round 1 --phase propose --timeout-ms 5000 \
     --label-map "$E3_LABEL_MAP" >/dev/null 2>&1; then
  QUORUM_RC=0
else
  QUORUM_RC=$?
fi
assert E2_quorum_exit "[[ $QUORUM_RC -eq 2 ]]"
assert E2_quorum_no_round2_dir "[[ ! -d \"$DEB3/round-2\" ]]"

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
target="$(printf '%s' "$spec" | sed -n 's/.*this file: //p' | head -1)"
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
E4_LABEL_MAP="$tmpdir/labels-e4.json"
debate_label_map_ensure "$E4_LABEL_MAP" e4slug "claude,codex,grok,gemini" >/dev/null
# Quorum (3 of 4) should still be met, so the round script is expected to exit 0 —
# but capture the real exit code rather than assuming it, since a regression here
# would abort the whole script, not merely flip 0 to 2.
E4_RC=0
ORCA_TEST_DISPATCH="$STUB/orca-dispatch-role-fail1.sh" \
ORCA_TEST_STATUS_STUB=completed \
"$ROUND" --dir "$DEB4" --round 1 --phase propose --timeout-ms 5000 \
  --label-map "$E4_LABEL_MAP" >/dev/null 2>&1 || E4_RC=$?
e4_claude_label="$(debate_label_of "$E4_LABEL_MAP" claude)"
e4_gemini_label="$(debate_label_of "$E4_LABEL_MAP" gemini)"
e4_grok_label="$(debate_label_of "$E4_LABEL_MAP" grok)"
e4_codex_label="$(debate_label_of "$E4_LABEL_MAP" codex)"
assert E4_survives_fail   "[[ $E4_RC -eq 0 ]]"
assert E4_others_present  "[[ -f \"$DEB4/round-1/$e4_claude_label.md\" && -f \"$DEB4/round-1/$e4_gemini_label.md\" && -f \"$DEB4/round-1/$e4_grok_label.md\" ]]"
assert E4_forfeit_missing "[[ ! -s \"$DEB4/round-1/$e4_codex_label.md\" ]]"

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
# A dedicated dir (not $tmpdir/debate4, already owned by the E4 block above).
# Round files are LABEL-named now (round-1/A.md, not round-1/claude.md) —
# realistic post-Task-3 fixture — and re-attribution happens via an external
# label map, so this test supplies one via --labels-dir rather than invoking
# the real (un-sandboxed) $DRIVER's own default $ORCH/debate-labels, which
# would resolve to this checkout's actual orchestration root. --labels-dir is
# exactly the override Task 3 added for this reason (see orca-debate.sh).
DEBF3="$tmpdir/debate-f3"
DEBF3_LABELS="$tmpdir/debate-f3-labels"
mkdir -p "$DEBF3/round-1" "$DEBF3/round-3" "$DEBF3_LABELS"
printf 'TOPIC_F3\n' > "$DEBF3/topic.md"
printf '# a\nAAA\n' > "$DEBF3/round-1/A.md"
printf '# b\nBBB\n' > "$DEBF3/round-3/B.md"
cat > "$DEBF3_LABELS/debate-f3.json" <<'JSON'
{"slug": "debate-f3", "roster": ["claude", "grok"], "labels": {"claude": "A", "grok": "B"}}
JSON
"$DRIVER" --build-transcript "$DEBF3" --labels-dir "$DEBF3_LABELS" >/dev/null 2>&1
assert F3_transcript "[[ -f \"$DEBF3/transcript.md\" ]]"
assert F3_has_topic  "grep -q TOPIC_F3 \"$DEBF3/transcript.md\""
assert F3_has_both   "grep -q AAA \"$DEBF3/transcript.md\" && grep -q BBB \"$DEBF3/transcript.md\""
assert F3_attributed_claude "grep -q 'claude' \"$DEBF3/transcript.md\""
assert F3_attributed_grok   "grep -q 'grok' \"$DEBF3/transcript.md\""

# Missing/unreadable label map: falls back to the raw label rather than
# crashing or leaving the section header blank.
DEBF3B="$tmpdir/debate-f3b"
mkdir -p "$DEBF3B/round-1"
printf 'TOPIC_F3B\n' > "$DEBF3B/topic.md"
printf '# a\nCCC\n' > "$DEBF3B/round-1/Z.md"
"$DRIVER" --build-transcript "$DEBF3B" --labels-dir "$tmpdir/no-such-labels-dir" >/dev/null 2>&1
assert F3B_falls_back_to_label "grep -q '### Z' \"$DEBF3B/transcript.md\""
assert F3B_body_kept          "grep -q CCC \"$DEBF3B/transcript.md\""

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
target="\$(printf '%s' "\$spec" | sed -n 's/.*this file: //p' | head -1)"
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

# ============================================================================
# Z-series: Task 3 (label-native anonymization) full lifecycle + concurrency
# refusal. Reuses the Q-series' already-sandboxed copies of the real driver
# scripts (q_scripts) and stubbed orca/CLI binaries (q_bin) — pure copies of
# the fixed source, unaffected by slug/topic, so there is no reason to
# re-copy them for a different scenario.
# ============================================================================

# --- Z1: a real 3-round debate end to end (propose -> critique -> converge),
# through the sandboxed driver + round script + a phase-aware dispatch stub
# that extracts its write target FROM THE SPEC TEXT (never computes its own
# label-to-path mapping) — the one place a stub could otherwise pass even if
# debate_spec regressed to short-name paths. Topic text deliberately contains
# no model name, since topic.md sits inside the debate directory too. ---
z_root="$tmpdir/z-lifecycle"
mkdir -p "$z_root"
Z_DRIVER="$q_scripts/orca-debate.sh"
Z_LABELS_DIR="$z_root/debate-labels"
Z_MANIFESTS_DIR="$z_root/debate-manifests"
Z_TOPIC="improve slow personal search across scattered notes"

z_stub_dir="$tmpdir/z-stub"
mkdir -p "$z_stub_dir"
z_spec_log="$tmpdir/z-specs.log"
: > "$z_spec_log"
cat > "$z_stub_dir/orca-dispatch-role.sh" <<SH
#!/usr/bin/env bash
role="\$1"; shift
spec=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --spec) spec="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
target="\$(printf '%s' "\$spec" | sed -n 's/.*this file: //p' | head -1)"
mkdir -p "\$(dirname "\$target")"
{
  echo "===== \$role ====="
  printf '%s\n' "\$spec"
  echo
} >> "$z_spec_log"
if printf '%s' "\$spec" | grep -q ': PROPOSE'; then
  {
    echo "# stub propose"
    echo "## Prior art"
    echo "## Proposals"
    echo "- Weakest link: stub"
    echo "## Directions I deliberately rejected"
  } > "\$target"
elif printf '%s' "\$spec" | grep -q ': CRITIQUE'; then
  {
    echo "# stub critique"
    echo "## Verdict per proposal"
    echo "Verdict: SURVIVE"
    echo "## Ranking"
    echo "## Merged proposals"
  } > "\$target"
else
  {
    echo "# stub converge"
    echo "## Differentiating axes"
    echo "## Niche candidates"
    echo "Kill condition: stub"
    echo "## Dissent"
  } > "\$target"
fi
echo "task_id=task_\${role}"
SH
chmod +x "$z_stub_dir/orca-dispatch-role.sh"

Z_OLD_PATH="$PATH"
export PATH="$q_bin:$PATH"
export ORCA_TEST_DISPATCH="$z_stub_dir/orca-dispatch-role.sh"
export ORCA_TEST_STATUS_STUB=completed
z_rc=0
"$Z_DRIVER" --topic "$Z_TOPIC" --slug zdebate --rounds 3 \
  --dir-root "$z_root/debates" --labels-dir "$Z_LABELS_DIR" \
  --manifests-dir "$Z_MANIFESTS_DIR" --lock-ttl-seconds 1800 \
  >"$z_root/driver.out" 2>"$z_root/driver.err" || z_rc=$?
unset ORCA_TEST_DISPATCH ORCA_TEST_STATUS_STUB
export PATH="$Z_OLD_PATH"

assert Z1_full_run_ok "[[ \"$z_rc\" -eq 0 ]]"
Z_DEBATE_DIR="$z_root/debates/zdebate"
assert Z1_debate_dir_exists "[[ -d \"$Z_DEBATE_DIR\" ]]"
# Each round directory existing is not enough — verify all 4 debaters
# actually landed usable, phase-appropriate content in EACH round, so a
# regression that quietly starves one round (as a wrong-path extraction bug
# in an earlier draft of this stub did to round 3, caught only by hand
# during this task's own self-review — see task-3-report.md) fails loudly
# here instead of hiding behind "the directory exists".
for z_round in 1 2 3; do
  z_round_file_count="$(find "$Z_DEBATE_DIR/round-$z_round" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d ' ')"
  assert "Z1_round${z_round}_has_four_files" "[[ \"$z_round_file_count\" -eq 4 ]]"
done
# All 4 files per round (not just at least one) carry the phase-appropriate
# marker — a wrong-path extraction bug (see comment above) would leave some
# or all of a round's real files EMPTY (never written) while the stub wrote
# the content somewhere else instead, so this checks the count, not just
# presence.
for z_check in '1:propose' '2:critique' '3:converge'; do
  z_r="${z_check%%:*}"
  z_marker="stub ${z_check#*:}"
  # `|| true` guards the same class of gotcha this file documents repeatedly
  # elsewhere: under this file's `set -o pipefail`, a round directory with
  # ZERO matching files makes the glob fail to expand, so `grep -l` receives
  # a literal, nonexistent path and exits non-zero — which pipefail would
  # otherwise propagate through `wc`/`tr` into this bare assignment and abort
  # the WHOLE suite via `set -e`, precisely on the exact regression
  # (round-N producing no real output) this assertion exists to catch. Found
  # by deliberately reproducing that exact regression during this task's own
  # self-review — see task-3-report.md.
  z_marked_count="$(grep -l "$z_marker" "$Z_DEBATE_DIR"/round-"$z_r"/*.md 2>/dev/null | wc -l | tr -d ' ' || true)"
  assert "Z1_round${z_r}_is_${z_check#*:}_content" "[[ \"${z_marked_count:-0}\" -eq 4 ]]"
done

# Step 1: nothing inside the completed debate directory names a model — in
# filenames OR contents — asserted over the WHOLE tree. transcript.md is the
# ONE deliberate, documented exception (build_transcript's own header
# comment; "Ambiguity resolved" in task-3-report.md): it is written only
# after the debate concludes, no round spec or debater instruction ever
# points a debater at it, and its entire purpose is re-attributing by short
# name for the human reader — checked separately below (Z1_transcript_is_
# attributed) so this is an asserted exception, not an unexamined gap.
z_tree_no_transcript="$tmpdir/z-tree-check"
rm -rf "$z_tree_no_transcript"
cp -R "$Z_DEBATE_DIR" "$z_tree_no_transcript"
rm -f "$z_tree_no_transcript/transcript.md"
assert Z1_no_model_names_in_contents \
  "! grep -rqiE 'claude|codex|grok|gemini' \"$z_tree_no_transcript\""
assert Z1_no_model_names_in_filenames \
  "[[ -z \"\$(find \"$z_tree_no_transcript\" | grep -iE 'claude|codex|grok|gemini')\" ]]"

# Step 6: the transcript DOES re-attribute by short name — the one place a
# short name is meant to appear.
assert Z1_transcript_is_attributed "grep -qi 'claude' \"$Z_DEBATE_DIR/transcript.md\""

# Step 3: round-2 (critique) and round-3 (converge) specs' read paths, taken
# literally, expose no authorship — verified against the FULL logged spec
# text of every real dispatch this run made (not just round 2), and none of
# them ever mentions a model name anywhere in the spec body either. The
# "===== $role =====" separator lines are this TEST's own logging (the role
# key, e.g. "debater_claude", is test harness bookkeeping — never sent to any
# debater), so they are stripped before checking; keeping them in would
# always fail this assertion regardless of debate_spec's actual output.
z_spec_log_body="$(grep -v '^===== ' "$z_spec_log" || true)"
assert Z1_specs_never_mention_model_names \
  "! printf '%s' \"\$z_spec_log_body\" | grep -qiE 'claude|codex|grok|gemini'"
assert Z1_critique_reads_round1_glob "grep -qF 'round-1/*.md' \"$z_spec_log\""
assert Z1_converge_reads_round2_glob "grep -qF 'round-2/*.md' \"$z_spec_log\""

# --- Z5 (Step 5 / deferred finding I1): re-running the SAME slug must not
# let a previous run's output count as this run's. Plant a leftover file
# that could not possibly have come from a real dispatch (wrong content) and
# a stale transcript, then re-run the identical slug for real — the
# driver's pre-round-1 wipe must remove both before anything is dispatched
# again. ---
mkdir -p "$Z_DEBATE_DIR/round-1"
printf 'THIS-IS-STALE-AND-MUST-NOT-SURVIVE\n' > "$Z_DEBATE_DIR/round-1/ZZ.md"
printf 'stale transcript from a previous run\n' > "$Z_DEBATE_DIR/transcript.md"

export PATH="$q_bin:$PATH"
export ORCA_TEST_DISPATCH="$z_stub_dir/orca-dispatch-role.sh"
export ORCA_TEST_STATUS_STUB=completed
z5_rc=0
"$Z_DRIVER" --topic "$Z_TOPIC" --slug zdebate --rounds 1 \
  --dir-root "$z_root/debates" --labels-dir "$Z_LABELS_DIR" \
  --manifests-dir "$Z_MANIFESTS_DIR" --lock-ttl-seconds 1800 \
  >"$z_root/driver2.out" 2>"$z_root/driver2.err" || z5_rc=$?
unset ORCA_TEST_DISPATCH ORCA_TEST_STATUS_STUB
export PATH="$Z_OLD_PATH"

assert Z5_rerun_ok "[[ \"$z5_rc\" -eq 0 ]]"
assert Z5_stale_leftover_file_wiped "[[ ! -f \"$Z_DEBATE_DIR/round-1/ZZ.md\" ]]"
assert Z5_stale_transcript_replaced \
  "[[ -f \"$Z_DEBATE_DIR/transcript.md\" ]] && ! grep -q 'stale transcript' \"$Z_DEBATE_DIR/transcript.md\""

# ----------------------------------------------------------------------------
# MX-series: Task 3 fix round 1 — the global mkdir-based startup mutex
# (debate_startup_mutex_acquire/_release, orca-debate-lib.sh) that closes the
# TOCTOU race in the ZC cross-slug concurrency refusal below. A plain
# scan-then-register sequence only protects against a driver whose lock
# ALREADY existed at scan time; since this driver's own lock is not written
# until AFTER the scan, two different-slug drivers started close together
# could each complete the scan, see nothing, and both proceed. These are
# pure, deterministic primitive-level tests (real concurrent processes, but
# proving mutual exclusion via a fixed, known hold duration rather than
# hoping to observe a fast, real-world race) — the real two-driver
# end-to-end demonstration is ZC3, further down, once q_scripts/q_bin exist.
# ----------------------------------------------------------------------------
mx_dir="$tmpdir/mutex"
mkdir -p "$mx_dir"

# --- MX1: real mutual exclusion under contention. Six concurrent
# contenders each acquire the SAME mutex directory, hold it for a fixed,
# known 0.2s (far longer than any real scheduling jitter on this machine),
# then release — logging their own [start,end] interval in nanoseconds. If
# acquire/release actually serialize (as mkdir's atomicity guarantees when
# used correctly), NO two logged intervals can ever overlap, deterministically
# — not "usually don't overlap." Any overlap is a genuine bug, confirmed
# below by mutation. ---
mx1_log="$mx_dir/mx1.log"
: > "$mx1_log"
mx1_pids=()
for _mx1_i in $(seq 1 6); do
  (
    # $BASHPID (a distinct-per-subshell pid) does not exist before bash 4 —
    # this repo's floor is bash 3.2 (macOS default), where `$$` inside a
    # forked `(...)` subshell still reports the TOP-LEVEL script's pid, not
    # this subshell's own. Not load-bearing for MX1 itself (which never
    # checks pid liveness, only interval overlap), but a real, distinct pid
    # is what a genuine caller would pass, so this uses one rather than a
    # shared, meaningless value.
    _mx1_own_pid="$(python3 -c 'import os; print(os.getpid())')"
    if debate_startup_mutex_acquire "$mx_dir" "$_mx1_own_pid" 5; then
      mx1_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
      sleep 0.2
      mx1_end_ns="$(python3 -c 'import time; print(time.time_ns())')"
      echo "$mx1_start_ns $mx1_end_ns" >> "$mx1_log"
      debate_startup_mutex_release "$mx_dir"
    else
      echo "TIMEOUT" >> "$mx1_log"
    fi
  ) &
  mx1_pids+=("$!")
done
for _mx1_pid in "${mx1_pids[@]}"; do
  wait "$_mx1_pid" 2>/dev/null || true
done

assert MX1_no_timeouts "! grep -q TIMEOUT \"$mx1_log\""
assert MX1_six_intervals_recorded "[[ \"\$(wc -l < \"$mx1_log\" | tr -d ' ')\" == '6' ]]"
mx1_overlap="$(python3 -c '
import sys
intervals = []
with open(sys.argv[1]) as f:
    for line in f:
        parts = line.split()
        if len(parts) == 2:
            intervals.append((int(parts[0]), int(parts[1])))
intervals.sort()
overlap = False
for i in range(1, len(intervals)):
    if intervals[i][0] < intervals[i - 1][1]:
        overlap = True
        break
print("OVERLAP" if overlap else "CLEAN")
' "$mx1_log")"
assert MX1_no_overlapping_intervals "[[ \"$mx1_overlap\" == 'CLEAN' ]]"

# --- MX2: a mutex held by a CONFIRMED-ALIVE owner is never stolen — acquire
# must time out (return 1) rather than assume clear. ---
mx2_dir="$mx_dir/mx2"
mkdir -p "$mx2_dir"
sleep 300 & mx2_holder_pid=$!
CLEANUP_PIDS+=("$mx2_holder_pid")
mkdir "$mx2_dir/.starting.lock"
printf '%s\n' "$mx2_holder_pid" > "$mx2_dir/.starting.lock/pid"
assert MX2_holder_pid_is_alive "kill -0 $mx2_holder_pid 2>/dev/null"
mx2_rc=0
debate_startup_mutex_acquire "$mx2_dir" "$$" 1 || mx2_rc=$?
assert MX2_times_out_when_alive_holder "[[ \"$mx2_rc\" -eq 1 ]]"
assert MX2_did_not_steal_alive_holder "[[ -d \"$mx2_dir/.starting.lock\" ]]"
kill -9 "$mx2_holder_pid" 2>/dev/null || true

# --- MX3: a STALE claim (recorded owner pid confirmed dead, AND old enough
# to rule out racing a peer that just mkdir'd) IS reclaimed — otherwise one
# crashed driver would deadlock every future debate start forever. ---
mx3_dir="$mx_dir/mx3"
mkdir -p "$mx3_dir"
( : ) & mx3_dead_pid=$!
wait "$mx3_dead_pid" 2>/dev/null || true
mkdir "$mx3_dir/.starting.lock"
printf '%s\n' "$mx3_dead_pid" > "$mx3_dir/.starting.lock/pid"
python3 -c "
import os, time
old = time.time() - 999
os.utime('$mx3_dir/.starting.lock', (old, old))
"
assert MX3_dead_pid_is_dead "! kill -0 $mx3_dead_pid 2>/dev/null"
mx3_rc=0
debate_startup_mutex_acquire "$mx3_dir" "$$" 3 || mx3_rc=$?
assert MX3_reclaims_stale_dead_owner "[[ \"$mx3_rc\" -eq 0 ]]"
debate_startup_mutex_release "$mx3_dir"
assert MX3_release_removed_it "[[ ! -d \"$mx3_dir/.starting.lock\" ]]"

# --- MX4: a YOUNG claim with NO pid file at all — a peer whose `mkdir` just
# succeeded and has not yet reached its own `printf … > pid` two lines
# later (a window of microseconds in real use) — must NOT be stolen. Fresh
# directory, mtime deliberately left untouched (this is the "fixture is
# what you think it is" check the previous round's fix-round retro calls
# for: an earlier draft of this exact test backdated the mtime to 999s
# instead, which made it silently test the OPPOSITE condition — an OLD
# pid-less claim — while its name and comment both claimed "young"; that
# mismatch is exactly how the permanent-deadlock bug this round fixes went
# unnoticed. A short max_wait (1s, well under the 2s stale threshold) keeps
# the directory genuinely young for this whole attempt.) ---
mx4_dir="$mx_dir/mx4"
mkdir -p "$mx4_dir"
mkdir "$mx4_dir/.starting.lock"
assert MX4_fixture_has_no_pid_file "[[ ! -f \"$mx4_dir/.starting.lock/pid\" ]]"
mx4_age_at_start="$(debate_dir_age_seconds "$mx4_dir/.starting.lock")"
assert MX4_fixture_is_actually_young "[[ \"$mx4_age_at_start\" -lt \"$DEBATE_STARTUP_MUTEX_STALE_SECONDS_DEFAULT\" ]]"
mx4_rc=0
debate_startup_mutex_acquire "$mx4_dir" "$$" 1 || mx4_rc=$?
assert MX4_young_pidless_not_reclaimed "[[ \"$mx4_rc\" -eq 1 ]]"
assert MX4_directory_left_alone "[[ -d \"$mx4_dir/.starting.lock\" ]]"
rm -rf "$mx4_dir/.starting.lock"

# --- MX6 (this round's fix — direct reproduction of the reported bug): an
# OLD claim with NO pid file at all — the previous holder crashed (SIGKILL/
# OOM/host crash, not a normal exit) in the gap between its own `mkdir` and
# its own pid write — is now reclaimed rather than blocking every future
# debate start forever. Matches the reviewer's exact reproduction: mtime
# backdated far in the past, no pid file ever written. ---
mx6_dir="$mx_dir/mx6"
mkdir -p "$mx6_dir"
mkdir "$mx6_dir/.starting.lock"
python3 -c "
import os, time
old = time.time() - 999
os.utime('$mx6_dir/.starting.lock', (old, old))
"
assert MX6_fixture_has_no_pid_file "[[ ! -f \"$mx6_dir/.starting.lock/pid\" ]]"
mx6_age_at_start="$(debate_dir_age_seconds "$mx6_dir/.starting.lock")"
assert MX6_fixture_is_actually_old "[[ \"$mx6_age_at_start\" -ge \"$DEBATE_STARTUP_MUTEX_STALE_SECONDS_DEFAULT\" ]]"
mx6_rc=0
debate_startup_mutex_acquire "$mx6_dir" "$$" 3 || mx6_rc=$?
assert MX6_old_pidless_reclaimed_not_timed_out "[[ \"$mx6_rc\" -eq 0 ]]"
debate_startup_mutex_release "$mx6_dir"
assert MX6_release_removed_it "[[ ! -d \"$mx6_dir/.starting.lock\" ]]"

# --- MX5: release is a safe no-op whether or not anything was ever held. ---
assert MX5_release_when_never_held_is_safe "debate_startup_mutex_release \"$mx_dir/never-touched\""

# --- ZC: concurrency refusal (Task 3 extra scope). A live lock for a
# DIFFERENT slug must block a brand-new debate from starting, with a reason
# naming the other slug; a STALE other-slug lock must NOT block (positive
# control — otherwise this would be far too conservative, given
# lock_is_fresh's own "stays fresh for up to ttlSeconds after the owner
# actually died" lag documented in orca-roles-lib.sh). Reuses Q_LOCKS_DIR
# (== "$q_root/debate-locks", since q_scripts' $ORCH resolves to $q_root) and
# the plain Q-series dispatch stub (--rounds 1, propose-only — no need for
# the phase-aware Z stub here). ---
lock_write "$Q_LOCKS_DIR/other-debate.json" "$$" other-debate 1800
assert ZC0_other_lock_is_fresh "lock_is_fresh \"$Q_LOCKS_DIR/other-debate.json\""

export PATH="$q_bin:$PATH"
export ORCA_TEST_DISPATCH="$q_stub_dir/orca-dispatch-role.sh"
export ORCA_TEST_STATUS_STUB=completed
zc_rc=0
zc_out="$("$Q_DRIVER" --topic "a second, unrelated debate" --slug new-debate --rounds 1 \
  --dir-root "$q_root/debates2" --lock-ttl-seconds 1800 2>&1)" || zc_rc=$?
unset ORCA_TEST_DISPATCH ORCA_TEST_STATUS_STUB
export PATH="$Z_OLD_PATH"

assert ZC1_refuses_when_other_slug_live "[[ \"$zc_rc\" -ne 0 ]]"
assert ZC1_names_the_other_slug "printf '%s' \"\$zc_out\" | grep -q 'other-debate'"
assert ZC1_never_created_own_lock "[[ ! -f \"$Q_LOCKS_DIR/new-debate.json\" ]]"
assert ZC1_never_dispatched_anything "[[ ! -d \"$q_root/debates2/new-debate/round-1\" ]]"

# Positive control: make that same lock STALE (heartbeat past its own tiny
# ttlSeconds) and confirm the identical attempt now succeeds.
python3 - "$Q_LOCKS_DIR/other-debate.json" <<'PY'
import json, datetime, sys
path = sys.argv[1]
d = json.load(open(path))
d["heartbeatAt"] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=999)).isoformat()
d["ttlSeconds"] = 5
with open(path, "w") as f:
    json.dump(d, f)
PY
assert ZC2_other_lock_now_stale "! lock_is_fresh \"$Q_LOCKS_DIR/other-debate.json\""

export PATH="$q_bin:$PATH"
export ORCA_TEST_DISPATCH="$q_stub_dir/orca-dispatch-role.sh"
export ORCA_TEST_STATUS_STUB=completed
zc2_rc=0
"$Q_DRIVER" --topic "a second, unrelated debate" --slug new-debate --rounds 1 \
  --dir-root "$q_root/debates2" --lock-ttl-seconds 1800 \
  >"$q_root/zc2.out" 2>"$q_root/zc2.err" || zc2_rc=$?
unset ORCA_TEST_DISPATCH ORCA_TEST_STATUS_STUB
export PATH="$Z_OLD_PATH"

assert ZC2_stale_other_lock_does_not_block "[[ \"$zc2_rc\" -eq 0 ]]"
assert ZC2_own_lock_cleaned_up_after_normal_exit "[[ ! -f \"$Q_LOCKS_DIR/new-debate.json\" ]]"

# --- ZC3 (Task 3 fix round 1, demonstration): two REAL drivers, DIFFERENT
# slugs, launched as close to simultaneously as bash allows, repeated across
# several fresh slug pairs — at most one may ever reach dispatch.
# ORCA_TEST_STARTUP_DELAY_S (a test-only seam in orca-debate.sh, never set in
# real usage) widens the critical section deterministically: whichever
# driver's `mkdir` wins holds the mutex for the full delay, which GUARANTEES
# the loser is still inside its own wait-loop when the winner finishes
# registering — so this proves the fix by construction rather than by
# hoping to win a real, sub-millisecond scheduling race. Each trial uses a
# fresh pair of slugs (no lock cleanup needed between trials) and its own
# --dir-root, so trials cannot interfere with each other. ---
zc3_trials=8
zc3_any_double_dispatch=0
zc3_any_neither_dispatch=0
for zc3_i in $(seq 1 "$zc3_trials"); do
  zc3_root="$tmpdir/zc3-$zc3_i"
  mkdir -p "$zc3_root"
  zc3_slug_a="zc3-a-$zc3_i"
  zc3_slug_b="zc3-b-$zc3_i"

  export PATH="$q_bin:$PATH"
  export ORCA_TEST_DISPATCH="$q_stub_dir/orca-dispatch-role.sh"
  export ORCA_TEST_STATUS_STUB=completed
  ORCA_TEST_STARTUP_DELAY_S=0.2 "$Q_DRIVER" --topic "race a $zc3_i" --slug "$zc3_slug_a" --rounds 1 \
    --dir-root "$zc3_root/debates" --lock-ttl-seconds 120 \
    >"$zc3_root/a.out" 2>"$zc3_root/a.err" &
  zc3_pid_a=$!
  ORCA_TEST_STARTUP_DELAY_S=0.2 "$Q_DRIVER" --topic "race b $zc3_i" --slug "$zc3_slug_b" --rounds 1 \
    --dir-root "$zc3_root/debates" --lock-ttl-seconds 120 \
    >"$zc3_root/b.out" 2>"$zc3_root/b.err" &
  zc3_pid_b=$!
  unset ORCA_TEST_DISPATCH ORCA_TEST_STATUS_STUB
  export PATH="$Q_OLD_PATH"

  zc3_rc_a=0
  zc3_rc_b=0
  wait "$zc3_pid_a" || zc3_rc_a=$?
  wait "$zc3_pid_b" || zc3_rc_b=$?

  zc3_a_dispatched=0
  zc3_b_dispatched=0
  if [[ -d "$zc3_root/debates/$zc3_slug_a/round-1" ]] \
     && [[ -n "$(find "$zc3_root/debates/$zc3_slug_a/round-1" -name '*.md' 2>/dev/null)" ]]; then
    zc3_a_dispatched=1
  fi
  if [[ -d "$zc3_root/debates/$zc3_slug_b/round-1" ]] \
     && [[ -n "$(find "$zc3_root/debates/$zc3_slug_b/round-1" -name '*.md' 2>/dev/null)" ]]; then
    zc3_b_dispatched=1
  fi

  if [[ "$zc3_a_dispatched" -eq 1 && "$zc3_b_dispatched" -eq 1 ]]; then
    zc3_any_double_dispatch=1
    echo "ZC3 trial $zc3_i: BOTH dispatched (rc_a=$zc3_rc_a rc_b=$zc3_rc_b) — the exact race this fix closes" >&2
  fi
  if [[ "$zc3_a_dispatched" -eq 0 && "$zc3_b_dispatched" -eq 0 ]]; then
    zc3_any_neither_dispatch=1
    echo "ZC3 trial $zc3_i: NEITHER dispatched (rc_a=$zc3_rc_a rc_b=$zc3_rc_b)" >&2
  fi
done
assert ZC3_never_both_dispatch_across_trials "[[ \"$zc3_any_double_dispatch\" -eq 0 ]]"
assert ZC3_exactly_one_dispatches_every_trial "[[ \"$zc3_any_neither_dispatch\" -eq 0 ]]"

# ============================================================================
# WD-series (Task 4): orca-wait-done.sh's new --task filter. The defect: bare
# `orca orchestration check` has no per-task selector, so a leftover message
# from an unrelated flow (a multi-round debate deliberately never drains its
# own worker_done backlog — draining via `check` would consume messages
# belonging to any concurrent flow, worse than the pollution) is the first
# thing a supervised wait sees. Pre-fix, orca-wait-done.sh acted on whatever
# arrived: closed FROM_HANDLE with no --role, or (with --role, exactly what
# orca-dispatch-role.sh --wait passes) resolved the close target from
# handles.json BY ROLE NAME regardless of which task the message was
# actually for. Both pre-fix failure modes were reproduced empirically
# against the unedited script before any change here (stubbed orca, one
# leftover worker_done for task_X with from_handle=term_debaterX):
#   no --role : closed term_debaterX (a debater's terminal, unrelated to
#               whatever the caller actually wanted)
#   --role thrifty (handles.json: thrifty -> term_thriftyReal) : closed
#               term_thriftyReal — thrifty's real, still-running terminal —
#               solely because of the role hint, even though the message
#               that triggered it belonged to an unrelated task
# Both are recorded in task-4-report.md; they are not re-asserted here as
# permanent tests because there is no old code path left to point them at
# once the fix lands (this file sources/exercises the FIXED script only) —
# same reasoning Task 1's H1 comment gives for its own pre-fix reproduction.
#
# All stubs below are on PATH inside a subshell/sandbox, never the real
# runtime. Every "orchestration check" stub is deliberately either (a) static
# per test (always the same non-matching or matching message, when a single
# poll settles the assertion) or (b) stateful via its own call-count log
# (when the test specifically needs to prove looping ACROSS separate polls,
# not just multiple messages within one poll) — WD4 and WD6 exist precisely
# because the brief warns a fixture with only one message per poll can never
# prove "examines all of them", and WD5/WD6 exist because a fixture that
# always matches on the first poll can never prove "the wait continues
# under the original overall timeout" across repeated polls.
# ============================================================================

# --- WD1: a message for a DIFFERENT task is never acted on, and the wait
# keeps polling (does not return) until the ORIGINAL overall timeout. ---
wd1_dir="$tmpdir/wd1"
mkdir -p "$wd1_dir/bin" "$wd1_dir/orch/scripts"
cp "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd1_dir/orch/scripts/"
chmod +x "$wd1_dir/orch/scripts/orca-wait-done.sh"
cat > "$wd1_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "orchestration check")
    echo call >> "$ORCA_WD1_DIR/check-calls.log"
    echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_debaterX","subject":"debate leftover","payload":{"taskId":"task_X"}}]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD1_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd1_dir/bin/orca"

wd1_rc=0
(
  export PATH="$wd1_dir/bin:$PATH"
  export ORCA_WD1_DIR="$wd1_dir"
  "$wd1_dir/orch/scripts/orca-wait-done.sh" --task task_Y --timeout-ms 900
) >"$wd1_dir/stdout.log" 2>"$wd1_dir/stderr.log" || wd1_rc=$?

wd1_calls="$(wc -l < "$wd1_dir/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD1_exits_zero "[[ \"$wd1_rc\" -eq 0 ]]"
assert WD1_never_closes "[[ ! -f \"$wd1_dir/closed.log\" ]]"
assert WD1_kept_polling "[[ \"${wd1_calls:-0}\" -ge 2 ]]"
assert WD1_reports_timeout "grep -q 'No matching message' \"$wd1_dir/stderr.log\""
assert WD1_logs_skipped_task "grep -q 'task=task_X' \"$wd1_dir/stderr.log\""
assert WD1_never_reports_a_match \
  "! grep -q 'Received type=worker_done subject=debate leftover' \"$wd1_dir/stderr.log\""

# --- WD2: the SAME stub message, but --task now matches — closes the
# expected handle, and does so on the first poll (no unnecessary looping). ---
wd2_dir="$tmpdir/wd2"
mkdir -p "$wd2_dir/bin" "$wd2_dir/orch/scripts"
cp "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd2_dir/orch/scripts/"
chmod +x "$wd2_dir/orch/scripts/orca-wait-done.sh"
cat > "$wd2_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "orchestration check")
    echo call >> "$ORCA_WD2_DIR/check-calls.log"
    echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_debaterX","subject":"debate leftover","payload":{"taskId":"task_X"}}]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD2_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd2_dir/bin/orca"

wd2_rc=0
(
  export PATH="$wd2_dir/bin:$PATH"
  export ORCA_WD2_DIR="$wd2_dir"
  "$wd2_dir/orch/scripts/orca-wait-done.sh" --task task_X --timeout-ms 5000
) >"$wd2_dir/stdout.log" 2>"$wd2_dir/stderr.log" || wd2_rc=$?

wd2_calls="$(wc -l < "$wd2_dir/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD2_exits_zero "[[ \"$wd2_rc\" -eq 0 ]]"
assert WD2_closes_target "grep -qx term_debaterX \"$wd2_dir/closed.log\""
assert WD2_settles_on_first_poll "[[ \"${wd2_calls:-0}\" -eq 1 ]]"
assert WD2_reports_received \
  "grep -qF 'Received type=worker_done subject=debate leftover from=term_debaterX task=task_X' \"$wd2_dir/stderr.log\""

# --- WD3: no --task at all reproduces today's behavior EXACTLY — same
# stub, same close decision, and (since the no-filter branch is the
# original code untouched) the exact original stderr strings: the literal
# --timeout-ms value (not a recomputed remaining budget) and no task-filter
# language anywhere. This is the permanent regression test for "existing
# callers are unaffected"; a live comparison against the pre-fix script
# itself would not be meaningful once the fix lands (see the WD-series
# header comment) so this asserts the documented invariant directly. ---
wd3_dir="$tmpdir/wd3"
mkdir -p "$wd3_dir/bin" "$wd3_dir/orch/scripts"
cp "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd3_dir/orch/scripts/"
chmod +x "$wd3_dir/orch/scripts/orca-wait-done.sh"
cat > "$wd3_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "orchestration check")
    echo call >> "$ORCA_WD3_DIR/check-calls.log"
    echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_debaterX","subject":"debate leftover","payload":{"taskId":"task_X"}}]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD3_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd3_dir/bin/orca"

wd3_rc=0
(
  export PATH="$wd3_dir/bin:$PATH"
  export ORCA_WD3_DIR="$wd3_dir"
  "$wd3_dir/orch/scripts/orca-wait-done.sh" --timeout-ms 1234
) >"$wd3_dir/stdout.log" 2>"$wd3_dir/stderr.log" || wd3_rc=$?

wd3_calls="$(wc -l < "$wd3_dir/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD3_exits_zero "[[ \"$wd3_rc\" -eq 0 ]]"
assert WD3_closes_from_handle "grep -qx term_debaterX \"$wd3_dir/closed.log\""
assert WD3_single_poll "[[ \"${wd3_calls:-0}\" -eq 1 ]]"
assert WD3_original_waiting_message \
  "grep -qF 'Waiting (types=worker_done,escalation,decision_gate timeout-ms=1234)…' \"$wd3_dir/stderr.log\""
assert WD3_original_received_message \
  "grep -qF 'Received type=worker_done subject=debate leftover from=term_debaterX task=task_X' \"$wd3_dir/stderr.log\""
assert WD3_no_task_filter_language "! grep -q 'timeout-ms=1234 task=' \"$wd3_dir/stderr.log\""

# --- WD4: a SINGLE `check` response carrying SEVERAL messages, where the
# matching one is NOT first. The brief warns this is exactly where a
# one-message fixture cannot prove "examines all of them" — three messages
# here, the wanted one in the middle, and the other two must be logged
# (not silently dropped) but never closed on. ---
wd4_dir="$tmpdir/wd4"
mkdir -p "$wd4_dir/bin" "$wd4_dir/orch/scripts"
cp "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd4_dir/orch/scripts/"
chmod +x "$wd4_dir/orch/scripts/orca-wait-done.sh"
cat > "$wd4_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "orchestration check")
    echo call >> "$ORCA_WD4_DIR/check-calls.log"
    echo '{"ok":true,"result":{"count":3,"messages":[
      {"type":"worker_done","from_handle":"term_other1","subject":"leftover1","payload":{"taskId":"task_other1"}},
      {"type":"worker_done","from_handle":"term_targetZ","subject":"the one we want","payload":{"taskId":"task_Z"}},
      {"type":"escalation","from_handle":"term_other2","subject":"leftover2","payload":{"taskId":"task_other2"}}
    ]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD4_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd4_dir/bin/orca"

wd4_rc=0
(
  export PATH="$wd4_dir/bin:$PATH"
  export ORCA_WD4_DIR="$wd4_dir"
  "$wd4_dir/orch/scripts/orca-wait-done.sh" --task task_Z --timeout-ms 5000
) >"$wd4_dir/stdout.log" 2>"$wd4_dir/stderr.log" || wd4_rc=$?

wd4_calls="$(wc -l < "$wd4_dir/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD4_exits_zero "[[ \"$wd4_rc\" -eq 0 ]]"
assert WD4_closes_the_middle_match "grep -qx term_targetZ \"$wd4_dir/closed.log\""
assert WD4_never_closes_first "! grep -qx term_other1 \"$wd4_dir/closed.log\""
assert WD4_never_closes_last "! grep -qx term_other2 \"$wd4_dir/closed.log\""
assert WD4_single_poll_sufficient "[[ \"${wd4_calls:-0}\" -eq 1 ]]"
assert WD4_logs_skipped_first "grep -q 'task=task_other1' \"$wd4_dir/stderr.log\""
assert WD4_logs_skipped_last "grep -q 'task=task_other2' \"$wd4_dir/stderr.log\""
assert WD4_reports_the_match \
  "grep -qF 'Received type=worker_done subject=the one we want from=term_targetZ task=task_Z' \"$wd4_dir/stderr.log\""

# --- WD5: the match arrives only after several SEPARATE polls (not within
# one batch) — proves the loop genuinely persists ACROSS `check` calls under
# the ORIGINAL overall timeout, not merely across messages within one call. ---
wd5_dir="$tmpdir/wd5"
mkdir -p "$wd5_dir/bin" "$wd5_dir/orch/scripts"
cp "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd5_dir/orch/scripts/"
chmod +x "$wd5_dir/orch/scripts/orca-wait-done.sh"
cat > "$wd5_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "orchestration check")
    n=0
    [[ -f "$ORCA_WD5_DIR/check-calls.log" ]] && n=$(wc -l < "$ORCA_WD5_DIR/check-calls.log" | tr -d ' ')
    echo call >> "$ORCA_WD5_DIR/check-calls.log"
    n=$((n + 1))
    if [[ "$n" -lt 3 ]]; then
      echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_noise","subject":"noise","payload":{"taskId":"task_noise"}}]}}'
    else
      echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_finally","subject":"the real one","payload":{"taskId":"task_final"}}]}}'
    fi
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD5_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd5_dir/bin/orca"

wd5_rc=0
(
  export PATH="$wd5_dir/bin:$PATH"
  export ORCA_WD5_DIR="$wd5_dir"
  "$wd5_dir/orch/scripts/orca-wait-done.sh" --task task_final --timeout-ms 5000
) >"$wd5_dir/stdout.log" 2>"$wd5_dir/stderr.log" || wd5_rc=$?

wd5_calls="$(wc -l < "$wd5_dir/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD5_exits_zero "[[ \"$wd5_rc\" -eq 0 ]]"
assert WD5_closes_after_persistence "grep -qx term_finally \"$wd5_dir/closed.log\""
assert WD5_never_closes_noise "! grep -qx term_noise \"$wd5_dir/closed.log\""
assert WD5_took_multiple_polls "[[ \"${wd5_calls:-0}\" -ge 3 ]]"
assert WD5_logged_noise "grep -q 'task=task_noise' \"$wd5_dir/stderr.log\""

# --- WD6: end-to-end through the REAL orca-dispatch-role.sh --wait, against
# a stub that queues two leftover "debate" worker_done messages (a different
# task id) ahead of this dispatch's own completion. Proves requirement #2
# directly (not just by grepping the source for the wiring): the task id
# orca-dispatch-role.sh just created via `orchestration task-create` is what
# actually reaches the exec'd orca-wait-done.sh's --task filter, so the
# leftover messages are ignored and only this dispatch's own message closes
# its own terminal. --no-reap keeps the background reaper out of the way
# (it is orthogonal to this defect and would otherwise linger for up to
# REAP_TIMEOUT_MS against this same stub). ---
wd6_dir="$tmpdir/wd6"
mkdir -p "$wd6_dir/bin" "$wd6_dir/scripts"
cp "$ROOT/scripts/orca-dispatch-role.sh" "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd6_dir/scripts/"
echo '{}' > "$wd6_dir/handles.json"
WD6_DISPATCH="$wd6_dir/scripts/orca-dispatch-role.sh"

cat > "$wd6_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal create") echo '{"ok":true,"result":{"terminal":{"handle":"term_wd6role"}}}' ;;
  "terminal rename") echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal send") echo '{"ok":true,"result":{"send":{"handle":"term_wd6role","accepted":true}}}' ;;
  "terminal read") echo '{"ok":true,"result":{"terminal":{"handle":"term_wd6role","tail":["ROLE=thrifty"]}}}' ;;
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_wd6role","connected":true}]}}' ;;
  "orchestration task-create") echo '{"ok":true,"result":{"task":{"id":"task_wd6_target"}}}' ;;
  "orchestration dispatch") echo '{"ok":true,"result":{"dispatch":{"id":"disp_wd6"}}}' ;;
  "orchestration check")
    n=0
    [[ -f "$ORCA_WD6_DIR/check-calls.log" ]] && n=$(wc -l < "$ORCA_WD6_DIR/check-calls.log" | tr -d ' ')
    echo call >> "$ORCA_WD6_DIR/check-calls.log"
    n=$((n + 1))
    if [[ "$n" -lt 3 ]]; then
      echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_debate_leftover","subject":"leftover debate worker_done","payload":{"taskId":"task_wd6_noise"}}]}}'
    else
      echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_wd6role","subject":"thrifty done","payload":{"taskId":"task_wd6_target"}}]}}'
    fi
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD6_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd6_dir/bin/orca"

wd6_rc=0
(
  export PATH="$wd6_dir/bin:$PATH"
  export ORCA_WD6_DIR="$wd6_dir"
  "$WD6_DISPATCH" thrifty --spec "irrelevant wd6 body" --wait --no-reap --timeout-ms 5000
) >"$wd6_dir/dispatch.out" 2>"$wd6_dir/dispatch.err" || wd6_rc=$?

wd6_calls="$(wc -l < "$wd6_dir/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD6_dispatch_wait_ok "[[ \"$wd6_rc\" -eq 0 ]]"
assert WD6_closes_own_handle "grep -qx term_wd6role \"$wd6_dir/closed.log\""
assert WD6_never_closes_leftover "! grep -qx term_debate_leftover \"$wd6_dir/closed.log\""
assert WD6_skipped_noise_task_logged "grep -q 'task=task_wd6_noise' \"$wd6_dir/dispatch.err\""
assert WD6_reports_target_task "grep -q 'task=task_wd6_target' \"$wd6_dir/dispatch.err\""
assert WD6_persisted_across_polls "[[ \"${wd6_calls:-0}\" -ge 3 ]]"

# --- WD7: usage/docs/wiring surface. ---
assert WD7_syntax_clean "bash -n \"$ROOT/scripts/orca-wait-done.sh\""
wd7_help_out="$("$ROOT/scripts/orca-wait-done.sh" --help 2>&1 || true)"
assert WD7_help_mentions_task "printf '%s' \"\$wd7_help_out\" | grep -q -- '--task'"
assert WD7_dispatch_wiring_passes_task \
  "grep -q -- '--role \"\$ROLE\" --task \"\$TASK_ID\"' \"$ROOT/scripts/orca-dispatch-role.sh\""
assert WD7_singlewaiter_documented_in_script \
  "grep -qi 'single-waiter' \"$ROOT/scripts/orca-wait-done.sh\""
assert WD7_singlewaiter_documented_in_docs \
  "grep -qi 'one waiter at a time' \"$ROOT/templates/SCRIPTS.md\""
assert WD7_dispatch_md_hint_has_ui_reviewer "grep -q 'ui|reviewer' \"$ROOT/commands/dispatch.md\""
assert WD7_close_md_hint_has_ui_reviewer "grep -q 'ui|reviewer' \"$ROOT/commands/close.md\""
assert WD7_fallback_md_hint_has_ui_reviewer "grep -q 'ui|reviewer' \"$ROOT/commands/fallback.md\""

# --- WD8: the ORIGINAL bug scenario verbatim, exercised directly on
# orca-wait-done.sh (not through orca-dispatch-role.sh, so a --role handle
# for a role OTHER than whoever the message actually came from is in play,
# not just "the one role this dispatch happens to own" as in WD6). handles
# .json maps thrifty -> term_thriftyReal (its real, currently-running
# terminal); the queued message is a leftover debate worker_done for an
# unrelated task, from_handle=term_debaterX. This is the exact fixture used
# for the pre-fix empirical demonstration recorded in task-4-report.md. ---
wd8_dir="$tmpdir/wd8"
mkdir -p "$wd8_dir/bin" "$wd8_dir/orch/scripts"
cp "$ROOT/scripts/orca-wait-done.sh" "$ROOT/scripts/orca-roles-lib.sh" "$wd8_dir/orch/scripts/"
chmod +x "$wd8_dir/orch/scripts/orca-wait-done.sh"
cat > "$wd8_dir/orch/handles.json" <<'JSON'
{"version":1,"roles":{"thrifty":{"handle":"term_thriftyReal"}},"thrifty":"term_thriftyReal"}
JSON
cat > "$wd8_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "orchestration check")
    echo call >> "$ORCA_WD8_DIR/check-calls.log"
    echo '{"ok":true,"result":{"count":1,"messages":[{"type":"worker_done","from_handle":"term_debaterX","subject":"debate leftover","payload":{"taskId":"task_X"}}]}}'
    ;;
  "terminal close")
    prev=""
    for a in "$@"; do
      if [[ "$prev" == "--terminal" ]]; then echo "$a" >> "$ORCA_WD8_DIR/closed.log"; fi
      prev="$a"
    done
    echo '{"ok":true}'
    ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$wd8_dir/bin/orca"

# (a) --role thrifty, NO --task (the pre-fix call shape): reproduces the
# original bug — closes thrifty's REAL terminal on the strength of an
# unrelated task's message. This is expected/documented behavior for the
# no-filter path (Step 3: unaffected), which is exactly why requirement #2
# (orca-dispatch-role.sh --wait always supplies --task) matters.
wd8a_rc=0
(
  export PATH="$wd8_dir/bin:$PATH"
  export ORCA_WD8_DIR="$wd8_dir/a"
  mkdir -p "$ORCA_WD8_DIR"
  "$wd8_dir/orch/scripts/orca-wait-done.sh" --role thrifty --timeout-ms 900
) >"$wd8_dir/a.out" 2>"$wd8_dir/a.err" || wd8a_rc=$?
assert WD8a_norole_filter_reproduces_bug "grep -qx term_thriftyReal \"$wd8_dir/a/closed.log\""

# (b) --role thrifty AND --task task_X (matching the message): the fixed
# path proceeds, since the message IS confirmed to be for the awaited task —
# role-hint resolution firing here is now safe.
wd8b_rc=0
(
  export PATH="$wd8_dir/bin:$PATH"
  export ORCA_WD8_DIR="$wd8_dir/b"
  mkdir -p "$ORCA_WD8_DIR"
  "$wd8_dir/orch/scripts/orca-wait-done.sh" --role thrifty --task task_X --timeout-ms 5000
) >"$wd8_dir/b.out" 2>"$wd8_dir/b.err" || wd8b_rc=$?
assert WD8b_matching_task_still_closes "grep -qx term_thriftyReal \"$wd8_dir/b/closed.log\""

# (c) --role thrifty AND --task task_Y (a DIFFERENT, unrelated task — the
# actual defect scenario): must NOT close thrifty's real terminal, must NOT
# close anything at all, and must keep polling instead of returning early.
wd8c_rc=0
(
  export PATH="$wd8_dir/bin:$PATH"
  export ORCA_WD8_DIR="$wd8_dir/c"
  mkdir -p "$ORCA_WD8_DIR"
  "$wd8_dir/orch/scripts/orca-wait-done.sh" --role thrifty --task task_Y --timeout-ms 900
) >"$wd8_dir/c.out" 2>"$wd8_dir/c.err" || wd8c_rc=$?
wd8c_calls="$(wc -l < "$wd8_dir/c/check-calls.log" 2>/dev/null | tr -d ' ')"
assert WD8c_exits_zero "[[ \"$wd8c_rc\" -eq 0 ]]"
assert WD8c_never_closes_thrifty "[[ ! -f \"$wd8_dir/c/closed.log\" ]]"
assert WD8c_kept_polling "[[ \"${wd8c_calls:-0}\" -ge 2 ]]"
assert WD8c_logs_the_leftover "grep -q 'task=task_X' \"$wd8_dir/c.err\""

# ----------------------------------------------------------------------------
# TG (terminal-readiness-gate Task 1): distinguish "gone" from "cannot tell",
# and isolate orca-bootstrap-roles.sh's per-role failures.
#
# Pre-fix reproductions for TG1/TG2/TG5 (a stubbed `orca` against the
# UNMODIFIED code, run BEFORE any of this task's changes were made) are
# recorded verbatim — command and output — in task-1-report.md; they are not
# re-embedded here as git-history fixtures because this file's own convention
# (see H5's comment above) is to record pre-fix repro in the report and let
# these tests assert only the fixed behavior, with mutation checks (also in
# the report) standing in for "does this test even fail without the fix".
# ----------------------------------------------------------------------------

# --- TG1: terminal_is_live must report "cannot tell" (2), not "definitely
# not live" (1), for a handle that IS present in a successfully-retrieved
# list but reports connected:false (a flap) — the exact defect A scenario.
# H4 (above) already covers live/absent/list-failure/malformed-json; this is
# the one combination H4 never exercised.
tg1_dir="$tmpdir/tg1"
mkdir -p "$tg1_dir/bin"
cat > "$tg1_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
echo '{"ok":true,"result":{"terminals":[{"handle":"term_tg_flap","connected":false}]}}'
exit 0
ORCASTUB
chmod +x "$tg1_dir/bin/orca"
tg1_rc=0
( export PATH="$tg1_dir/bin:$PATH"; terminal_is_live term_tg_flap ) || tg1_rc=$?
assert TG1_present_disconnected_is_cannot_tell "[[ \"$tg1_rc\" -eq 2 ]]"

# --- TG2/TG3: orca-close-role.sh against a flapping handle. Sandboxed the
# same way as R5's close_sandbox (own copy of the two files, own handles.json
# — orca-close-role.sh checks its role whitelist before handles.json, and
# once past it falls through to a real `orca` call, so this must not run
# against the actual repo root).
tg23_dir="$tmpdir/tg23"
mkdir -p "$tg23_dir/scripts" "$tg23_dir/bin"
cp "$ROOT/scripts/orca-close-role.sh" "$ROOT/scripts/orca-roles-lib.sh" "$tg23_dir/scripts/"
cat > "$tg23_dir/handles.json" <<'JSON'
{"version":1,"roles":{"architect":{"handle":"term_tg_flap"}},"architect":"term_tg_flap"}
JSON
cat > "$tg23_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_tg_flap","connected":false}]}}' ;;
  "terminal close") echo '{"ok":true}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$tg23_dir/bin/orca"
tg2_out="$(PATH="$tg23_dir/bin:$PATH" "$tg23_dir/scripts/orca-close-role.sh" architect 2>&1)"
assert TG2_flapping_not_reported_already_gone \
  "! printf '%s' \"\$tg2_out\" | grep -q 'already gone'"
assert TG2_flapping_close_is_attempted \
  "printf '%s' \"\$tg2_out\" | grep -q 'Closing architect'"

# --- TG3: a close whose target is still live+connected immediately
# afterward (the close call itself reported {"ok":true} but nothing actually
# changed) must be reported LOUDLY and exit non-zero — never silently
# swallowed as "may already be gone".
tg3_dir="$tmpdir/tg3"
mkdir -p "$tg3_dir/scripts" "$tg3_dir/bin"
cp "$ROOT/scripts/orca-close-role.sh" "$ROOT/scripts/orca-roles-lib.sh" "$tg3_dir/scripts/"
cat > "$tg3_dir/handles.json" <<'JSON'
{"version":1,"roles":{"architect":{"handle":"term_tg_stuck"}},"architect":"term_tg_stuck"}
JSON
cat > "$tg3_dir/bin/orca" <<'ORCASTUB'
#!/usr/bin/env bash
case "$1 $2" in
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_tg_stuck","connected":true}]}}' ;;
  "terminal close") echo '{"ok":true}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
chmod +x "$tg3_dir/bin/orca"
tg3_rc=0
tg3_out="$(PATH="$tg3_dir/bin:$PATH" "$tg3_dir/scripts/orca-close-role.sh" architect 2>&1)" || tg3_rc=$?
assert TG3_stuck_close_exits_nonzero "[[ \"$tg3_rc\" -ne 0 ]]"
assert TG3_stuck_close_reported_loudly \
  "printf '%s' \"\$tg3_out\" | grep -qi 'STILL LIVE'"

# --- TG4/TG5/TG6: orca-bootstrap-roles.sh failure isolation. A dedicated
# stub understands `terminal create` (echoes a handle derived from --title),
# `terminal send` (fails for one specific handle only, everyone else
# succeeds), and `terminal read` (echoes back the exact handle asked for, so
# seed()'s read-back gate — which requires the handle in the response to
# match — passes for every role whose send succeeded).
tg_bootstrap_stub() {
  # $1=bin_dir $2=fail_create_title (or "") $3=fail_send_title (or "")
  local dir="$1" fail_create="$2" fail_send="$3"
  cat > "$dir/orca" <<ORCASTUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "terminal create")
    title=""
    prev=""
    for a in "\$@"; do
      if [[ "\$prev" == "--title" ]]; then title="\$a"; fi
      prev="\$a"
    done
    if [[ "\$title" == "$fail_create" && -n "$fail_create" ]]; then
      echo "stub: simulated create failure for \$title" >&2
      exit 1
    fi
    echo "{\\"ok\\":true,\\"result\\":{\\"terminal\\":{\\"handle\\":\\"term_\${title}\\"}}}"
    ;;
  "terminal rename") echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal send")
    term=""
    prev=""
    for a in "\$@"; do
      if [[ "\$prev" == "--terminal" ]]; then term="\$a"; fi
      prev="\$a"
    done
    # Independent of handles.json (which is populated during the CREATE
    # phase and would still show every handle even if the SEED phase aborted
    # outright) — this is the only signal that the seed step itself was
    # actually reached for a given handle, which is what TG4 needs to catch
    # a regression back to "one role's seed failure aborts the rest".
    [[ -n "\${TG_SEND_LOG:-}" ]] && printf '%s\n' "\$term" >> "\$TG_SEND_LOG"
    if [[ "\$term" == "term_$fail_send" && -n "$fail_send" ]]; then
      echo "stub: simulated send failure for \$term" >&2
      exit 1
    fi
    echo '{"ok":true,"result":{"send":{"handle":"'"\$term"'","accepted":true}}}'
    ;;
  "terminal read")
    term=""
    prev=""
    for a in "\$@"; do
      if [[ "\$prev" == "--terminal" ]]; then term="\$a"; fi
      prev="\$a"
    done
    echo '{"ok":true,"result":{"terminal":{"handle":"'"\$term"'","tail":[]}}}'
    ;;
  "status --json") echo '{"ok": true, "reachable": true}' ;;
  *) echo '{"ok":true}' ;;
esac
exit 0
ORCASTUB
  chmod +x "$dir/orca"
}

# TG4: seed fails for role-sol-executor (the 2nd of the 4 roles bootstrap
# creates — architect, executor, thrifty, fallback, in that order). Every
# role's terminal is still created; the failure must not strand roles 1's
# already-durable handle, and roles 3/4 must still be attempted.
tg4_dir="$tmpdir/tg4"
mkdir -p "$tg4_dir/orch/scripts" "$tg4_dir/orch/bin"
cp "$ROOT/scripts/orca-bootstrap-roles.sh" "$ROOT/scripts/orca-roles-lib.sh" "$tg4_dir/orch/scripts/"
tg_bootstrap_stub "$tg4_dir/orch/bin" "" "role-sol-executor"
tg4_send_log="$tg4_dir/send.log"
: > "$tg4_send_log"
tg4_rc=0
(
  cd "$tg4_dir"
  export TG_SEND_LOG="$tg4_send_log"
  PATH="$tg4_dir/orch/bin:$PATH" "$tg4_dir/orch/scripts/orca-bootstrap-roles.sh" --worktree active --project-name tg4
) >"$tg4_dir/out.log" 2>"$tg4_dir/err.log" || tg4_rc=$?
assert TG4_seed_failure_exits_nonzero "[[ \"$tg4_rc\" -ne 0 ]]"
assert TG4_all_four_handles_recorded \
  "python3 -c \"import json; d=json.load(open('$tg4_dir/orch/handles.json')); assert sorted(d['roles'].keys())==['architect','executor','fallback','thrifty'], d['roles'].keys()\""
assert TG4_names_failed_role "grep -q 'executor' \"$tg4_dir/out.log\" \"$tg4_dir/err.log\""
# The real, handles.json-independent proof that failure isolation (not a
# lucky partial abort) is what happened: the seed step was actually REACHED
# for the failing role itself, and for both roles after it.
assert TG4_executor_seed_reached "grep -qx term_role-sol-executor \"$tg4_send_log\""
assert TG4_thrifty_seed_attempted \
  "grep -qx term_role-grok-thrifty \"$tg4_send_log\""
assert TG4_fallback_seed_attempted \
  "grep -qx term_role-agy-fallback \"$tg4_send_log\""

# TG5: create_role itself fails for the 2nd role (thrifty/grok this time, to
# exercise a DIFFERENT role than TG4) — roles 1, 3, and 4 must still be
# created and durably recorded; the failed role must have no handle at all.
tg5_dir="$tmpdir/tg5"
mkdir -p "$tg5_dir/orch/scripts" "$tg5_dir/orch/bin"
cp "$ROOT/scripts/orca-bootstrap-roles.sh" "$ROOT/scripts/orca-roles-lib.sh" "$tg5_dir/orch/scripts/"
tg_bootstrap_stub "$tg5_dir/orch/bin" "role-grok-thrifty" ""
tg5_rc=0
(
  cd "$tg5_dir"
  PATH="$tg5_dir/orch/bin:$PATH" "$tg5_dir/orch/scripts/orca-bootstrap-roles.sh" --worktree active --project-name tg5
) >"$tg5_dir/out.log" 2>"$tg5_dir/err.log" || tg5_rc=$?
assert TG5_create_failure_exits_nonzero "[[ \"$tg5_rc\" -ne 0 ]]"
assert TG5_names_failed_role "grep -q 'thrifty' \"$tg5_dir/out.log\" \"$tg5_dir/err.log\""
assert TG5_architect_recorded "grep -q term_role-opus-architect \"$tg5_dir/orch/handles.json\""
assert TG5_executor_recorded "grep -q term_role-sol-executor \"$tg5_dir/orch/handles.json\""
assert TG5_fallback_recorded "grep -q term_role-agy-fallback \"$tg5_dir/orch/handles.json\""
assert TG5_thrifty_has_no_handle \
  "python3 -c \"import json; d=json.load(open('$tg5_dir/orch/handles.json')); v=d['roles'].get('thrifty',{}).get('handle'); assert not v, v\""

# TG6: all-succeed path — regression guard that bootstrap's observable
# end-state (all four handles recorded, exit 0, final messages) did not
# change shape from this rewrite, even though the per-role loop now
# interleaves handles_set into the create phase instead of batching it at
# the very end (see task-1-report.md for the byte-level equality check
# against the pre-fix script run against this exact fixture).
tg6_dir="$tmpdir/tg6"
mkdir -p "$tg6_dir/orch/scripts" "$tg6_dir/orch/bin"
cp "$ROOT/scripts/orca-bootstrap-roles.sh" "$ROOT/scripts/orca-roles-lib.sh" "$tg6_dir/orch/scripts/"
tg_bootstrap_stub "$tg6_dir/orch/bin" "" ""
tg6_rc=0
(
  cd "$tg6_dir"
  PATH="$tg6_dir/orch/bin:$PATH" "$tg6_dir/orch/scripts/orca-bootstrap-roles.sh" --worktree active --project-name tg6
) >"$tg6_dir/out.log" 2>"$tg6_dir/err.log" || tg6_rc=$?
assert TG6_all_succeed_exits_zero "[[ \"$tg6_rc\" -eq 0 ]]"
assert TG6_all_succeed_says_done "grep -q '^Done\\.' \"$tg6_dir/out.log\""
assert TG6_all_four_recorded \
  "python3 -c \"import json; d=json.load(open('$tg6_dir/orch/handles.json')); assert sorted(d['roles'].keys())==['architect','executor','fallback','thrifty'], d['roles'].keys()\""

echo
echo "Results: $pass passed, $fail failed"
[[ "$fail" -gt 0 ]] && exit 1
exit 0
