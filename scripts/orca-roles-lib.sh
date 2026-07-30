#!/usr/bin/env bash
# Shared helpers for role bootstrap / dispatch / close.
# Sourced only — do not execute. No set -e here (callers own shell options).
# Single source for role launch strings (not roles.yaml).

role_meta() {
  # $1=role → title<TAB>model<TAB>agent
  case "$1" in
    architect) printf '%s\t%s\t%s\n' "role-opus-architect" "claude-opus-5" "claude" ;;
    executor)  printf '%s\t%s\t%s\n' "role-sol-executor"   "gpt-5.6-sol"     "codex" ;;
    thrifty)   printf '%s\t%s\t%s\n' "role-grok-thrifty"   "grok-4.5"        "grok" ;;
    ui)        printf '%s\t%s\t%s\n' "role-agy-ui"         "Gemini 3.6 Flash (Medium)" "antigravity" ;;
    reviewer)  printf '%s\t%s\t%s\n' "role-opus-reviewer"  "claude-opus-5"   "claude" ;;
    fallback)  printf '%s\t%s\t%s\n' "role-agy-fallback"   "Gemini 3.6 Flash (Medium)" "antigravity" ;;
    debater_claude) printf '%s\t%s\t%s\n' "debate-opus"  "claude-opus-5" "claude" ;;
    debater_codex)  printf '%s\t%s\t%s\n' "debate-sol"   "gpt-5.6-sol"   "codex" ;;
    debater_grok)   printf '%s\t%s\t%s\n' "debate-grok"  "grok-4.5"      "grok" ;;
    debater_gemini) printf '%s\t%s\t%s\n' "debate-agy"   "Gemini 3.6 Flash (Medium)" "antigravity" ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
}

role_launch_cmd() {
  # $1=role → CLI launch command string
  case "$1" in
    architect)
      printf '%s\n' 'claude --model claude-opus-5 --dangerously-skip-permissions'
      ;;
    executor)
      printf '%s\n' 'codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox'
      ;;
    thrifty)
      printf '%s\n' 'grok --model grok-4.5 --permission-mode bypassPermissions'
      ;;
    ui)
      printf '%s\n' 'agy --model "Gemini 3.6 Flash (Medium)" --dangerously-skip-permissions'
      ;;
    reviewer)
      printf '%s\n' 'claude --model claude-opus-5 --dangerously-skip-permissions'
      ;;
    fallback)
      printf '%s\n' 'agy --model "Gemini 3.6 Flash (Medium)" --dangerously-skip-permissions'
      ;;
    debater_claude)
      printf '%s\n' 'claude --model claude-opus-5 --dangerously-skip-permissions'
      ;;
    debater_codex)
      printf '%s\n' 'codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox'
      ;;
    debater_grok)
      printf '%s\n' 'grok --model grok-4.5 --permission-mode bypassPermissions'
      ;;
    debater_gemini)
      printf '%s\n' 'agy --model "Gemini 3.6 Flash (Medium)" --dangerously-skip-permissions'
      ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
}

role_fallback_body() {
  case "$1" in
    architect) printf '%s\n' "Own architecture, judgment, high-risk review, long-horizon plans. Prefer plans/reviews over bulk implementation." ;;
    executor)  printf '%s\n' "Own hard implementation, terminal loops, verification, final integration. Execute approved plans end-to-end." ;;
    thrifty)   printf '%s\n' "Own small tickets, maps, research, prototypes, high-volume low-risk edits. Escalate design risk." ;;
    ui)        printf '%s\n' "Own the user-visible surface and cheap design drafts. Every draft returns to architect for approval. Never change system structure." ;;
    reviewer)  printf '%s\n' "FINAL PRE-MERGE GATE ONLY. Return APPROVE or BLOCK with file:line evidence. Never edit. architect keeps day-to-day review." ;;
    fallback)  printf '%s\n' "Rate/session-limit safety net. Continue interrupted tasks with smallest viable progress." ;;
    debater_claude) printf '%s\n' "Idea debate participant, principle and risk lens. Argue from long-horizon coherence, failure modes, and regulatory exposure. Read-only: write only to the output file named in your spec." ;;
    debater_codex)  printf '%s\n' "Idea debate participant, feasibility lens. Argue from build cost, technical risk, and the shortest credible path to a shippable slice. Read-only: write only to the output file named in your spec." ;;
    debater_grok)   printf '%s\n' "Idea debate participant, contrarian and market lens. Surface angles nobody is taking and sweep prior art. Read-only: write only to the output file named in your spec." ;;
    debater_gemini) printf '%s\n' "Idea debate participant, demand and user lens. Argue from jobs-to-be-done, concrete usage scenarios, and evidence of real demand. Read-only: write only to the output file named in your spec." ;;
    *) return 1 ;;
  esac
}

is_debater() {
  case "$1" in
    debater_*) return 0 ;;
    *) return 1 ;;
  esac
}

dispatch_tail_block() {
  # $1=handle  $2=close|persist
  local handle="$1" mode="${2:-close}"
  if [[ "$mode" == "persist" ]]; then
    cat <<EOF

STAY-OPEN (required):
After you send worker_done exactly once, do NOT close this terminal and do NOT
run any close command. Stay idle and wait for the next dispatch in this debate.
Do not poll orchestration.
Your Orca terminal handle for this session is: ${handle}
The debate driver closes this tab when the debate ends.
EOF
  else
    cat <<EOF

AUTO-CLOSE (required, automatic):
After you send worker_done exactly once, immediately run this shell command (do not skip):
  orca terminal close --terminal ${handle} --tab --json
Your Orca terminal handle for this session is: ${handle}
Then stop. Do not poll orchestration. A background reaper also closes this tab if needed.
EOF
  fi
}

dispatch_status() {
  # $1=task_id → dispatch status word (never fails)
  orca orchestration dispatch-show --task "$1" --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown")
    raise SystemExit(0)
r = d.get("result") or d
disp = r.get("dispatch") or r
print(disp.get("status") or "unknown")
' 2>/dev/null || echo "unknown"
}

create_role() {
  # $1=title $2=command $3=role (optional; recorded in the journal only — may
  #   be empty/unknown, e.g. orca-bootstrap-roles.sh's direct 2-arg calls)
  #
  # On success: prints the handle on stdout, returns 0.
  # On failure to find a handle in the create response: returns 1 with
  # nothing on stdout. It does this via an explicit check, NOT by raising —
  # the old code's `raise SystemExit("no handle…")` relied on that exception
  # propagating up through `set -e` to stop the caller, but under this
  # repo's bash (3.2.57, macOS default — no `inherit_errexit`), a
  # command-substitution subshell always runs with errexit OFF regardless of
  # the parent's `set -e`. Verified empirically: `handle="$(create_role …)"`
  # inside `ensure_terminal` did NOT abort on that SystemExit — it silently
  # continued with handle="", which `handles_set` then wrote into
  # handles.json, and a later `orca terminal send --terminal ""` fell back to
  # the CLI's "active terminal" — i.e. the exact observed bug where a seed
  # landed in the coordinator's own session. So every step from here on
  # checks status explicitly (`||`, `if !`) instead of trusting propagation.
  #
  # The raw create response is journaled to $ORCH/terminal-journal.jsonl
  # BEFORE this function decides success/failure, in the same python process
  # that parses it (not two separate steps), so a parse problem can never
  # skip the write, and a journal I/O problem can never suppress an
  # otherwise-successful handle. A null `handle` next to a non-null `raw` in
  # that journal is the signal an orphan sweep looks for: a terminal was
  # created (raw response exists) but its handle was never recorded anywhere.
  local title="$1" command="$2" role="${3:-}" journal_file raw handle handle_scratch
  echo "→ Creating $title" >&2
  raw="$(orca terminal create --worktree "$WORKTREE" --title "$title" --command "$command" --json)" || raw=""
  journal_file="${ORCH:-.}/terminal-journal.jsonl"
  mkdir -p "$(dirname "$journal_file")" 2>/dev/null || true
  # The python heredoc below writes ITS OWN stdout to a scratch file via a
  # plain `>` redirect, then a separate trivial `$(cat …)` reads it back —
  # it is deliberately NOT `handle="$(python3 … <<'PY' … PY)"`. On this
  # repo's bash (3.2.57, macOS default), a quoted-delimiter heredoc (`<<'PY'`)
  # nested directly inside a `$(...)` command substitution can break the
  # substitution's own paren-matching if the heredoc body's quote/paren
  # counts aren't globally even — even though the body is supposed to be
  # fully literal. Confirmed empirically on this bash: a heredoc body
  # containing nothing but a stray "don't" (one unmatched apostrophe) is
  # enough to make `bash -n` fail with "unexpected EOF looking for matching
  # `)'" several lines later, with no error located anywhere near the actual
  # apostrophe. `handles_get`/`handles_set` below never hit this because
  # their heredocs run as plain (uncaptured) commands, never inside `$(...)`.
  handle_scratch="${journal_file}.handle.$$"
  python3 - "$journal_file" "$role" "$title" "$raw" <<'PY' >"$handle_scratch"
import json, sys, datetime

path, role, title, raw = sys.argv[1:5]
try:
    parsed = json.loads(raw) if raw else None
except Exception:
    parsed = None

handle = ""
if isinstance(parsed, dict):
    result = parsed.get("result") or parsed
    if isinstance(result, dict):
        handle = (
            result.get("handle")
            or (result.get("terminal") or {}).get("handle")
            or parsed.get("handle")
            or ""
        )

row = {
    "role": role or None,
    "title": title,
    "raw": parsed if parsed is not None else raw,
    "handle": handle or None,
    "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
# A journal I/O problem is a second, independent failure. It must not
# masquerade as "no handle in the create response" by suppressing a handle
# that was parsed successfully, so this warns instead of gating on it.
try:
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")
except Exception as exc:
    print(f"create_role: could not append {path}: {exc}", file=sys.stderr)

print(handle)
PY
  handle="$(cat "$handle_scratch" 2>/dev/null)"
  rm -f "$handle_scratch" 2>/dev/null
  if [[ -z "$handle" ]]; then
    echo "create_role: no handle in terminal create response for '$title' (role=${role:-unknown}) — the terminal may exist but is untracked; see $journal_file (handle=null) for the raw response" >&2
    return 1
  fi
  orca terminal rename --terminal "$handle" --title "$title" --json >/dev/null 2>&1 || true
  echo "  handle=$handle" >&2
  printf '%s\n' "$handle"
}

# Intentionally unchanged: still warns and returns 0 on a tui-idle timeout
# rather than failing hard. Two reasons this is in scope, not a leftover:
# (1) orca-bootstrap-roles.sh calls this as a bare top-level statement for
#     each of the 4 primary roles (lines 66-69) — making it fail loud would
#     abort bootstrap for all subsequent roles over one role's harmless
#     90s timeout, a regression for ordinary dispatch of all 6 roles; and
# (2) handles_set now runs before this (see ensure_terminal), so the handle
#     is already durable by the time this runs, and seed()'s own send/
#     read-back verification independently catches a terminal that never
#     actually became usable. Neither of the two "what must become true"
#     requirements this task is scoped to depends on this function's status.
wait_idle() {
  orca terminal wait --terminal "$1" --for tui-idle --timeout-ms 90000 --json >/dev/null 2>&1 \
    || echo "  (warn) tui-idle wait timed out for $1" >&2
}

# ---------------------------------------------------------------------------
# Terminal readiness gate (Task 2 — the fix the whole plan exists for).
#
# THE DEFECT: `wait_idle` above waits on `orca terminal wait --for tui-idle`,
# which means only "the TUI stopped redrawing" — a blank, not-yet-drawn
# screen satisfies that instantly. A four-model debate built on this repo
# produced zero output across five live runs: every debater's terminal was
# seeded, and later dispatched into via `--inject`, while it was still
# booting (claude/codex hadn't reached a prompt yet, codex had exited, grok
# was on its first-run menu, agy sat on an empty screen) — tui-idle alone
# had already reported success in every one of those states.
#
# THE FIX: `terminal_wait_ready` below POLLS (never answers from a single
# snapshot) up to a deadline, combining three independent signals rather
# than trusting any one alone (a positive prompt pattern alone would
# silently break at the next CLI release):
#   1. a minimum elapsed-time FLOOR — only when the caller knows a genuine
#      creation timestamp (see the ensure_terminal-vs-dispatch-role
#      discussion on terminal_wait_ready below); even a snapshot that
#      matches every other signal is not trusted before this floor;
#   2. tui-idle, the same primitive `wait_idle` uses ("as today") — reused
#      here as a per-iteration settle/pace wait, not removed;
#   3. actual screen content, read via `orca terminal read` and classified
#      by `_terminal_ready_check` into READY / NOT_READY(reason): a known
#      not-ready marker (first-run menu text, a trust/theme prompt, a
#      terminal whose process has exited) vetoes readiness; a positive
#      per-CLI prompt pattern, when one is known, is REQUIRED for READY —
#      but is checked BEFORE the negative markers, so a CLI whose working
#      prompt can legitimately coexist with leftover first-run text (see
#      the grok note inside _terminal_ready_check) is not permanently
#      blocked by that text once it truly is ready.
#
# This never sends a keystroke to dismiss anything. A first-run trust/theme
# screen is reported — with its exact matched text — so a human can clear it
# once, by hand. See task-2-report.md for the full pattern-set rationale,
# the grok menu-vs-prompt decision, and the pre/post-fix demonstrations.
# ---------------------------------------------------------------------------

# Overridable for tests. Production defaults are deliberately conservative:
# this task's whole premise is that a real CLI cold start takes longer than
# a glance suggests, and misjudging a READY terminal as not-ready blocks
# ordinary dispatch for all six pre-existing roles, not just debaters — so
# the bias throughout is toward waiting longer, never toward failing fast.
: "${ROLE_READY_TIMEOUT_SECONDS:=60}"
: "${ROLE_READY_POLL_INTERVAL_SECONDS:=2}"
: "${ROLE_READY_MIN_ELAPSED_SECONDS:=3}"
: "${ROLE_SEED_MARKER_RETRIES:=5}"
: "${ROLE_SEED_MARKER_INTERVAL_SECONDS:=1}"

_terminal_ready_check() {
  # $1=handle $2=cli (claude|codex|grok|antigravity|"" for unknown) → stdout
  # line 1 is the verdict ("READY" or "NOT_READY: <reason>"); remaining
  # lines are the raw screen tail, always included (never discarded on a
  # not-ready verdict) so a caller can report exactly what was on screen.
  #
  # Same scratch-file + plain `cat` precaution used by create_role/lock_pid/
  # lock_handles above: this function's own stdout is meant to be captured
  # via `$(...)` by terminal_wait_ready below, so the python heredoc writes
  # to a scratch file via a plain `>` redirect instead of being captured in
  # the same step — never `verdict="$(python3 ... <<'PY' ... PY)"` directly.
  local handle="$1" cli="$2" read_json scratch
  read_json="$(orca terminal read --terminal "$handle" --limit 200 --json 2>/dev/null)" || read_json=""
  scratch="$(mktemp)"
  # $read_json is passed as an argv element, NOT piped to stdin: `python3 -`
  # already claims stdin for the heredoc script body below, so piping data
  # into the same fd would collide with it (concatenating onto the script
  # source rather than being readable as separate input). Same argv-not-
  # stdin data-passing convention create_role uses for its own `$raw`.
  python3 - "$handle" "$cli" "$read_json" >"$scratch" <<'PY'
import json, sys

handle, cli, raw = sys.argv[1], sys.argv[2], sys.argv[3]


def emit(verdict, lines):
    print(verdict)
    for ln in lines:
        print(ln)


try:
    d = json.loads(raw) if raw.strip() else None
except Exception:
    d = None

if not isinstance(d, dict) or not d.get("ok"):
    emit(
        "NOT_READY: could not read terminal (orca terminal read failed or "
        "returned no output) -- transient, not a verdict on the screen itself",
        ["(unreadable)"],
    )
    raise SystemExit(0)

term = (d.get("result") or {}).get("terminal")
if not isinstance(term, dict) or term.get("handle") != handle:
    emit(
        "NOT_READY: terminal read did not return this handle's own terminal "
        "(structural mismatch) -- transient",
        ["(unreadable)"],
    )
    raise SystemExit(0)

tail = term.get("tail")
if not isinstance(tail, list):
    emit("NOT_READY: terminal read returned no tail array -- transient", ["(unreadable)"])
    raise SystemExit(0)

lines = [str(x) for x in tail]
joined = "\n".join(lines)
status = term.get("status")

# A terminal whose process has already exited (codex's observed pre-fix
# failure mode) will never become ready no matter how long we poll. Only a
# small, explicit "known dead" set vetoes on status -- an unrecognized
# future status string is left alone, so it can never silently misjudge a
# genuinely-running terminal as gone.
BAD_STATUSES = {"exited", "dead", "stopped", "crashed", "terminated", "closed"}
if isinstance(status, str) and status.strip().lower() in BAD_STATUSES:
    emit(f"NOT_READY: terminal status={status!r} -- the CLI process is not running", lines or ["(no output)"])
    raise SystemExit(0)

if not joined.strip():
    emit("NOT_READY: blank screen (no output yet -- CLI still booting)", ["(blank)"])
    raise SystemExit(0)


def has_prompt_line(needle):
    return any(ln.strip().startswith(needle) for ln in lines)


# Positive per-CLI ready pattern, checked BEFORE negative markers below. See
# the grok row of the observed-data table: its ready prompt "may sit below a
# first-run menu" -- the menu text can be genuinely present on a terminal
# that, right now, is fully able to receive input (confirmed directly: text
# sent to a grok terminal on this exact screen was accepted and answered
# normally). Vetoing on menu text regardless of prompt presence would also
# risk misjudging `thrifty` (a pre-existing PRODUCTION role that launches
# grok, not a debater) as not-ready every time that menu lingers on screen --
# exactly the regression this task warns against. So a CLI's own positive
# prompt match, when it matches, wins outright; negative markers are only
# evaluated when the positive check does not (yet) confirm readiness.
positive_known = True
if cli == "claude":
    ready = has_prompt_line("❯") and ("bypass permissions on" in joined)
    positive_desc = "'❯' prompt + 'bypass permissions on' status line"
elif cli == "grok":
    ready = has_prompt_line("❯")
    positive_desc = "'❯' prompt"
elif cli == "antigravity":
    # Two sub-cases, not one: the observed-data table's phrasing ("'>'
    # prompt AFTER an Antigravity CLI banner") describes a BOOT SEQUENCE,
    # and ensure_terminal's gate (fresh creation only -- the reuse path
    # never re-seeds or re-gates) is the only caller that is guaranteed to
    # see that banner still on screen. orca-dispatch-role.sh's own gate
    # runs on every dispatch, including to a WARM, already-running ui/
    # fallback terminal (ordinary dispatch reuses live terminals) whose
    # banner may have scrolled out of a full-screen TUI's current frame
    # long ago -- requiring it unconditionally would risk misjudging an
    # ordinary, already-ready production terminal as not-ready on every
    # dispatch (advisor review flagged this directly: unverified against a
    # real live agy session, and the safer assumption is that it might not
    # persist). So: banner present -> corroborate with ANY prompt-shaped
    # line (matches the boot sequence verbatim). Banner absent (warm case)
    # -> require the prompt to be the CURRENT LAST non-blank line, not just
    # present anywhere -- a stricter, position-based signal a bare
    # "anywhere in the tail" check can't give, and specifically one a
    # mid-response markdown blockquote ("> quoted text") would NOT satisfy
    # unless it happened to be the terminal's literal last rendered line.
    def is_agy_prompt_line(ln):
        s = ln.strip()
        return s == ">" or s.startswith("> ")

    banner_present = "Antigravity CLI" in joined
    nonblank_lines = [ln for ln in lines if ln.strip()]
    if banner_present:
        ready = any(is_agy_prompt_line(ln) for ln in lines)
    else:
        ready = bool(nonblank_lines) and is_agy_prompt_line(nonblank_lines[-1])
    positive_desc = (
        "'Antigravity CLI' banner + any '>' prompt line (fresh boot), "
        "or a trailing '>' prompt as the terminal's current last line (warm)"
    )
else:
    # codex (no ready screen was ever captured -- the brief is explicit
    # about this; inventing a pattern we have no evidence for is worse than
    # having none) and any unrecognized/empty cli.
    positive_known = False
    ready = False
    positive_desc = ""

if positive_known and ready:
    emit("READY", lines)
    raise SystemExit(0)

GENERIC_NEGATIVE = [
    # Real, known first-run screens for `claude` specifically (this
    # project's own CLI): a trust dialog and a theme-selection wizard.
    # Treated as generic (checked for every cli) rather than claude-only,
    # since we have no positive evidence they are impossible on any other
    # CLI either, and false-veto risk here is low -- both phrases are
    # distinctive, multi-word, and not the kind of text a normal ready
    # prompt would ever incidentally contain.
    "Do you trust the files in this folder",
    "Select a theme",
]
CLI_NEGATIVE = {
    # Verbatim from the observed-data table. Deliberately EXCLUDES the
    # table's own "Quit" entry: it is a single common word plausibly present
    # in an ordinary ready screen's own footer/hint text (e.g. "ctrl+c to
    # quit"), and the self-review directive here is to bias against
    # misjudging a genuinely ready terminal as not-ready -- precision over
    # recall for this one marker. The other three are multi-word, specific,
    # and were not observed on any ready screen.
    "grok": ["New worktree", "Resume session", "Changelog"],
}
for marker in GENERIC_NEGATIVE + CLI_NEGATIVE.get(cli, []):
    if marker in joined:
        emit(f"NOT_READY: matched not-ready marker {marker!r} (cli={cli or 'unknown'})", lines)
        raise SystemExit(0)

if positive_known:
    emit(f"NOT_READY: no {cli} ready prompt matched yet (looking for {positive_desc})", lines)
    raise SystemExit(0)

# No known positive pattern for this CLI (codex; also an unrecognized/empty
# cli) and nothing vetoed it -- readiness rests on the other two signals
# (elapsed floor + tui-idle, both applied by the caller) plus "not blank,
# nothing bad matched". Per the brief: a positive pattern, when available,
# is confirmation, not the sole requirement -- so its ABSENCE must not
# itself block a CLI we simply have no captured ready screen for.
emit("READY", lines)
PY
  cat "$scratch"
  rm -f "$scratch"
}

terminal_wait_ready() {
  # $1=handle $2=cli (claude|codex|grok|antigravity|"" for unknown)
  # $3=not_before_epoch (optional; 0 or omitted = no floor — see below)
  #
  # Polls _terminal_ready_check until ROLE_READY_TIMEOUT_SECONDS elapses.
  # Returns 0 the moment a poll reports READY (and $3's floor, if any, has
  # passed); returns 1 only after the FULL deadline, printing the LAST
  # observed screen to stderr. Never a single-shot verdict (a screen that
  # becomes ready partway through the window is still caught on a later
  # iteration), and never a silent failure — 25 minutes of silence with no
  # indication of what the screen showed is the exact failure this task
  # exists to eliminate.
  #
  # $3 is a caller-supplied ABSOLUTE epoch, not "elapsed since this call
  # started": ensure_terminal knows a genuine creation timestamp for a
  # terminal it just created and passes created_epoch +
  # ROLE_READY_MIN_ELAPSED_SECONDS. orca-dispatch-role.sh's own gate (before
  # --inject) does NOT know a creation time for a handle it merely resolved
  # (it may have just been created moments ago by ensure_terminal above,
  # which already applied this floor once before seeding, or it may be a
  # long-warm terminal from a prior dispatch) and passes no floor at all —
  # restarting a multi-second floor on every ordinary dispatch to an
  # already-ready, already-warm terminal would add pure, unrequested latency
  # to the six pre-existing roles' hot path for no safety benefit.
  local handle="$1" cli="${2:-}" not_before="${3:-0}"
  local deadline_epoch now_epoch verdict reason screen
  now_epoch="$(date +%s)"
  deadline_epoch=$((now_epoch + ROLE_READY_TIMEOUT_SECONDS))
  reason="(no check performed)"
  screen="(none)"

  while :; do
    now_epoch="$(date +%s)"
    verdict="$(_terminal_ready_check "$handle" "$cli")"
    reason="$(printf '%s\n' "$verdict" | head -n1)"
    screen="$(printf '%s\n' "$verdict" | tail -n +2)"

    if [[ "$reason" == "READY" ]] && { [[ "$not_before" -eq 0 ]] || [[ "$now_epoch" -ge "$not_before" ]]; }; then
      return 0
    fi

    [[ "$now_epoch" -ge "$deadline_epoch" ]] && break
    orca terminal wait --terminal "$handle" --for tui-idle \
      --timeout-ms "$((ROLE_READY_POLL_INTERVAL_SECONDS * 1000))" --json >/dev/null 2>&1 || true
    sleep "$ROLE_READY_POLL_INTERVAL_SECONDS"
  done

  echo "terminal_wait_ready: $handle (cli=${cli:-unknown}) never became ready within ${ROLE_READY_TIMEOUT_SECONDS}s -- last check: $reason" >&2
  echo "----- $handle screen (most recent) -----" >&2
  printf '%s\n' "$screen" >&2
  echo "-----------------------------------------" >&2
  return 1
}

persona_body() {
  # $1 = role key. Echo persona file content minus the H1 and the STANCE comment.
  # Return non-zero if the file is absent (caller falls back to a hardcoded one-liner).
  local role="$1" file="${ORCH:-.}/personas/$role.md"
  [[ -f "$file" ]] || return 1
  grep -vE '^# |^<!-- STANCE:' "$file"
}

seed_text() {
  # $1=role $2=model $3=body → full seed message on stdout
  local role="$1" model="$2" body="$3" ending
  if is_debater "$role"; then
    ending="When you receive an Orca orchestration dispatch preamble, follow it exactly and send worker_done once with taskId+dispatchId.
This terminal is one seat in a multi-round debate: after worker_done, stay open and idle until the next round's dispatch arrives. Never close this terminal yourself.
Write only to the output file named in your dispatch spec. Never edit any other file. Never run git commit or git add.
Until a dispatch arrives, acknowledge role and wait."
  else
    ending="When you receive an Orca orchestration dispatch preamble, follow it exactly and send worker_done once with taskId+dispatchId.
End of task (automatic close): after worker_done, immediately run
  orca terminal close --terminal <YOUR_HANDLE> --tab --json
using the handle given in the dispatch AUTO-CLOSE block. Then stop — no polling, no check loop.
A background reaper also closes the tab; self-close is belt-and-suspenders.
Until a dispatch arrives, acknowledge role and wait."
  fi
  cat <<EOF
You are ROLE=$role on model $model in an Orca multi-agent setup for ${PROJECT_NAME:-project}.

$body

Project constraints:
${CONSTRAINTS:-Follow repository conventions; never commit secrets.}
Never commit secrets (.env, keys, *.pem).
Model disagreement → project SSOT docs + current code win.

$ending
EOF
}

seed() {
  # $1=handle $2=role $3=model $4=fallback_body
  #
  # Verifies its own send instead of discarding the result: (a) refuses a
  # target that isn't shaped like a real terminal handle, (b) requires the
  # send call to structurally report success, (c) confirms the exact handle
  # is still a live, readable terminal right after sending. Any of these
  # failing is echoed to stderr and returns 1 — never swallowed. seed_text's
  # output itself is untouched by any of this (non-debater seed text is
  # byte-frozen).
  local handle="$1" role="$2" model="$3" fallback_body="$4"
  local body text send_json accepted read_ok attempt read_json marker
  local marker_seen marker_read_json

  case "$handle" in
    term_*) ;;
    *)
      echo "seed: refusing to send — '$handle' is not a term_*-shaped terminal handle (role=$role). This guard exists because an empty/blank --terminal previously fell back to the CLI's active terminal, i.e. a seed misdelivered to an unrelated session." >&2
      return 1
      ;;
  esac

  if body="$(persona_body "$role")" && [[ -n "${body// }" ]]; then
    : # use full persona file
  else
    body="$fallback_body"
  fi
  text="$(seed_text "$role" "$model" "$body")"

  send_json="$(orca terminal send --terminal "$handle" --text "$text" --enter --json)"
  if [[ -z "${send_json// }" ]]; then
    echo "seed: orca terminal send produced no output for $handle (role=$role) — treating as failed" >&2
    return 1
  fi
  accepted="$(printf '%s' "$send_json" | python3 -c '
import json, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print("false")
    raise SystemExit(0)
r = d.get("result") or d
s = r.get("send") or r
ok = s.get("accepted")
if ok is None:
    ok = d.get("ok")
print("true" if ok else "false")
')"
  if [[ "$accepted" != "true" ]]; then
    echo "seed: send not accepted for $handle (role=$role): $send_json" >&2
    return 1
  fi

  # Confirm arrival by reading the terminal back. The hard gate is
  # structural only — the exact handle is still a live, queryable terminal
  # right after the send — not a match on the literal sent text: the target
  # is a full-screen TUI agent (claude/codex/grok/agy) that redraws its own
  # scrollback, so asserting on rendered content would race that redraw and
  # be flaky. A short marker check below is a soft, non-fatal signal only.
  read_ok=1
  for attempt in 1 2 3; do
    read_json="$(orca terminal read --terminal "$handle" --limit 200 --json 2>/dev/null)" || read_json=""
    if [[ -n "${read_json// }" ]] && printf '%s' "$read_json" | python3 -c '
import json, sys

h = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
r = (d.get("result") or {}).get("terminal") or {}
sys.exit(0 if (d.get("ok") and r.get("handle") == h and isinstance(r.get("tail"), list)) else 1)
' "$handle"; then
      read_ok=0
      break
    fi
    [[ "$attempt" -lt 3 ]] && sleep 0.5
  done
  if [[ "$read_ok" -ne 0 ]]; then
    echo "seed: could not confirm $handle is still a live, readable terminal after send (role=$role) — seed may not have landed" >&2
    return 1
  fi

  # Task 2, requirement 4: this marker check becomes a HARD GATE WITH
  # RETRIES for debater_* roles only. A debate round dispatches into every
  # seat within seconds of seeding (see the terminal_wait_ready file-header
  # defect narrative above) with no human watching any individual terminal,
  # so a seed that silently never landed is indistinguishable from "will
  # show up eventually" until the whole round times out 25 minutes later.
  # The six pre-existing roles are dispatched one at a time and this
  # specific behavior must not change for them — so the non-debater branch
  # below is the exact pre-Task-2 soft/informational check, untouched.
  marker="ROLE=$role"
  if is_debater "$role"; then
    marker_seen=0
    marker_read_json="$read_json"
    attempt=0
    while [[ "$attempt" -lt "$ROLE_SEED_MARKER_RETRIES" ]]; do
      attempt=$((attempt + 1))
      if printf '%s' "$marker_read_json" | grep -qF "$marker"; then
        marker_seen=1
        break
      fi
      [[ "$attempt" -lt "$ROLE_SEED_MARKER_RETRIES" ]] || break
      sleep "$ROLE_SEED_MARKER_INTERVAL_SECONDS"
      marker_read_json="$(orca terminal read --terminal "$handle" --limit 200 --json 2>/dev/null)" || marker_read_json=""
    done
    if [[ "$marker_seen" -ne 1 ]]; then
      echo "seed: HARD FAIL for debater role=$role handle=$handle — marker '$marker' never appeared after $attempt attempt(s). This is a hard gate for debater_* roles only (Task 2): the seed did not land, and the caller must not proceed as if it did." >&2
      return 1
    fi
  else
    # Unchanged: soft, best-effort confirmation only — an info note (not a
    # failure) if the seed's own opening marker isn't visible yet — the
    # agent's TUI may have already redrawn past it by the time we read.
    if ! printf '%s' "$read_json" | grep -qF "$marker"; then
      echo "seed: (info) marker '$marker' not visible yet in $handle's tail — not a failure, TUI may have redrawn already" >&2
    fi
  fi

  return 0
}

handles_get() {
  # $1=handles_file $2=role → handle or empty
  local file="$1" role="$2"
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$role" <<'PY'
import json, sys
path, role = sys.argv[1:3]
try:
    d = json.load(open(path))
except Exception:
    print("")
    raise SystemExit(0)
h = (d.get("roles") or {}).get(role, {}).get("handle") or d.get(role) or ""
print(h)
PY
}

handles_set() {
  # $1=handles_file $2=role $3=handle — update that role's handle (and top-level key)
  local file="$1" role="$2" handle="$3"
  python3 - "$file" "$role" "$handle" <<'PY'
import json, sys, datetime, os
path, role, handle = sys.argv[1:4]
meta = {
    "architect": {"title": "role-opus-architect", "model": "claude-opus-5", "agent": "claude"},
    "executor":  {"title": "role-sol-executor",   "model": "gpt-5.6-sol",     "agent": "codex"},
    "thrifty":   {"title": "role-grok-thrifty",   "model": "grok-4.5",        "agent": "grok"},
    "ui":        {
        "title": "role-agy-ui",
        "model": "Gemini 3.6 Flash (Medium)",
        "agent": "antigravity",
        "cli": "agy",
    },
    "reviewer":  {"title": "role-opus-reviewer",  "model": "claude-opus-5",   "agent": "claude"},
    "fallback":  {
        "title": "role-agy-fallback",
        "model": "Gemini 3.6 Flash (Medium)",
        "agent": "antigravity",
        "cli": "agy",
    },
    "debater_claude": {"title": "debate-opus", "model": "claude-opus-5", "agent": "claude"},
    "debater_codex":  {"title": "debate-sol",  "model": "gpt-5.6-sol",   "agent": "codex"},
    "debater_grok":   {"title": "debate-grok", "model": "grok-4.5",      "agent": "grok"},
    "debater_gemini": {
        "title": "debate-agy",
        "model": "Gemini 3.6 Flash (Medium)",
        "agent": "antigravity",
        "cli": "agy",
    },
}
d = json.load(open(path)) if os.path.exists(path) else {"version": 1, "roles": {}}
d.setdefault("roles", {})
d[role] = handle
row = dict(meta.get(role) or {})
row["handle"] = handle
d["roles"][role] = row
d["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(f"handles_set {role}={handle}", file=sys.stderr)
PY
}

terminal_is_live() {
  # $1=handle → 0 definitely live / 1 definitely not live / 2 could not
  # determine. Callers must treat 2 as "leave it alone": never recreate,
  # never assume gone, on the strength of an inconclusive check — only exit
  # 1 (definite dead) should ever be actioned as "gone". Previously any
  # non-zero (including a failed `orca terminal list`) read as "dead", so a
  # transient list failure could make ensure_terminal spin up a duplicate
  # terminal for a role whose original was still running.
  #
  # "Could not determine" now ALSO covers a handle that IS present in a
  # successfully-retrieved list but reports connected:false (a flap) — not
  # just a list call that failed outright. Those are two different facts:
  # absent from the list means the terminal is gone; present-but-momentarily-
  # disconnected means we simply do not know yet. Observed live: a handle
  # present with connected:false got reported as exit 1 ("definitely not
  # live") by the old code, cleanup logged "already gone (ok)" and skipped
  # closing it, and an immediate follow-up query on that same handle came
  # back connected:true — the terminal, and its permission-bypass session,
  # had never actually gone anywhere. Only an ABSENT handle is exit 1 now;
  # present-but-disconnected is exit 2, same as an unreadable list.
  local handle="$1" list_json rc=0
  list_json="$(orca terminal list --json 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 || -z "${list_json// }" ]]; then
    return 2
  fi
  printf '%s' "$list_json" | python3 -c '
import json, sys

h = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if d.get("ok") is False:
    sys.exit(2)
result = d.get("result")
if not isinstance(result, dict):
    sys.exit(2)
terminals = result.get("terminals")
if not isinstance(terminals, list):
    sys.exit(2)
# Checked as three separate facts, in this order, rather than folded into
# one boolean expression: a duplicate/stale entry for the same handle could
# otherwise let a disconnected copy shadow a connected one depending on list
# order. any(... and connected) is tried FIRST and independently of presence,
# so a connected entry anywhere in the list still wins exit 0 regardless of
# what any other same-handle entry says.
if any(t.get("handle") == h and t.get("connected") for t in terminals):
    sys.exit(0)
if any(t.get("handle") == h for t in terminals):
    sys.exit(2)
sys.exit(1)
' "$handle"
}

terminal_close_and_verify() {
  # $1=handle → attempts to close the terminal, then CONFIRMS it is actually
  # gone instead of trusting the close call's own reported success. Returns:
  #   0 = confirmed gone (terminal_is_live now reports 1, absent from the list)
  #   1 = STILL LIVE after the close attempt — a real, loud failure. Never
  #       swallowed: closes were previously reported as success unconditionally,
  #       which is exactly how a permission-bypassed session could survive a
  #       driver that believed it had cleaned up.
  #   2 = could not confirm either way (liveness undetermined, e.g. `orca
  #       terminal list` itself failed) — soft. Per terminal_is_live's own
  #       contract, 2 is never proof of anything and callers must not treat
  #       it as a hard failure.
  #
  # A successful close is not necessarily reflected in `orca terminal list`
  # the instant the close call returns (the same kind of propagation lag
  # seed()'s own read-back already retries around), so "still live" is only
  # trusted as a genuine failure after a few short retries — one true
  # negative read (rc=1, gone) or one inconclusive read (rc=2) is accepted
  # immediately, without waiting out the rest of the retry budget, since
  # neither of those needs re-checking.
  local handle="$1" verify_rc=0 attempt
  orca terminal close --terminal "$handle" --tab --json >/dev/null 2>&1 \
    || orca terminal close --terminal "$handle" --json >/dev/null 2>&1 \
    || true
  for attempt in 1 2 3; do
    verify_rc=0
    terminal_is_live "$handle" || verify_rc=$?
    [[ "$verify_rc" -ne 0 ]] && break
    [[ "$attempt" -lt 3 ]] && sleep 0.5
  done
  case "$verify_rc" in
    1)
      return 0
      ;;
    0)
      echo "terminal_close_and_verify: $handle is STILL LIVE after a close attempt (checked $attempt time(s)) — the close did not take effect" >&2
      return 1
      ;;
    2)
      echo "terminal_close_and_verify: could not confirm $handle is gone after the close attempt (liveness undetermined — present but disconnected, or orca terminal list unavailable)" >&2
      return 2
      ;;
  esac
}

ensure_terminal() {
  # $1=role → guaranteed-live handle on stdout.
  # Contract: stdout carries a handle ONLY when it is confirmed created,
  # durably recorded in $HANDLES_FILE, and seeded. Any failure along the way
  # returns 1 with nothing on stdout; recovery state (if any) lives in
  # $HANDLES_FILE and terminal-journal.jsonl, never only in this function's
  # local variables — so a seed failure still leaves a closable terminal.
  local role="$1" handle title model agent live_rc=0 created_epoch
  handle="$(handles_get "$HANDLES_FILE" "$role")"
  if [[ -n "$handle" ]]; then
    terminal_is_live "$handle" || live_rc=$?
    case "$live_rc" in
      0)
        printf '%s\n' "$handle"
        return 0
        ;;
      2)
        # Could not determine — never treat "undetermined" as "dead": that
        # is exactly how a live terminal used to get a duplicate created
        # alongside it.
        echo "Role $role handle $handle: liveness undetermined (present but disconnected, or orca terminal list unavailable) — leaving it alone, not recreating" >&2
        printf '%s\n' "$handle"
        return 0
        ;;
      *)
        echo "Role $role handle $handle is dead — recreating…" >&2
        ;;
    esac
  else
    echo "Role $role has no handle — creating…" >&2
  fi

  created_epoch="$(date +%s)"
  IFS=$'\t' read -r title model agent < <(role_meta "$role")
  handle="$(create_role "$title" "$(role_launch_cmd "$role")" "$role")" || {
    echo "ensure_terminal: create_role failed for role=$role — see terminal-journal.jsonl for the raw create response" >&2
    return 1
  }

  # Durable before anything that can fail: a wait_idle timeout, a
  # readiness-gate timeout, or a seed failure below must still leave this
  # handle closable via handles_get → terminal_is_live → close, instead of
  # leaking an untracked bypass-permissions session.
  if ! handles_set "$HANDLES_FILE" "$role" "$handle"; then
    echo "ensure_terminal: handles_set failed to record handle=$handle for role=$role — terminal exists but is NOT durably tracked in $HANDLES_FILE (see terminal-journal.jsonl)" >&2
    return 1
  fi

  wait_idle "$handle"

  # Gate (Task 2): confirm the actual screen, not tui-idle alone, before
  # seeding — this is the fix. See the "Terminal readiness gate" section
  # above terminal_wait_ready's definition for the full composition.
  if ! terminal_wait_ready "$handle" "$agent" "$((created_epoch + ROLE_READY_MIN_ELAPSED_SECONDS))"; then
    echo "ensure_terminal: $handle for role=$role never showed a ready screen — refusing to seed. Handle is recorded in $HANDLES_FILE so it can still be closed/retried; see the screen dump above for what to clear by hand." >&2
    return 1
  fi

  if ! seed "$handle" "$role" "$model" "$(role_fallback_body "$role")"; then
    echo "ensure_terminal: seed failed for role=$role handle=$handle — handle is recorded in $HANDLES_FILE so it can still be closed/retried; not printing it as a ready handle" >&2
    return 1
  fi

  printf '%s\n' "$handle"
}

# ---------------------------------------------------------------------------
# Generic ownership-lock primitives (Task 2: orphan sweeper + dead-man
# watchdog for `--persist`). Deliberately NOT debate-specific in name or
# behavior — any `--persist` dispatch can register a handle here, and the
# concept (an owner pid, a set of handles it is responsible for, a
# heartbeat + TTL that defines staleness) has nothing debate-specific in it.
# `orca-debate.sh` is the only current caller of lock_write, because it is
# the only current owner of a multi-round `--persist` flow, but this file —
# already the single source for role metadata and the terminal journal — is
# the natural home for the primitive, not scripts/orca-debate-lib.sh.
#
# Lock file contract ($ORCH/debate-locks/<slug>.json — see
# task-2-report.md for the full data contract table):
#   {"pid": <owner pid>, "slug": "...", "handles": [...],
#    "heartbeatAt": "<ISO-8601 UTC>", "ttlSeconds": <int>}
#
# Every write below goes through a temp-file + atomic rename (os.replace),
# never a direct in-place write — this file's entire purpose is surviving
# a process that gets killed without warning, and an in-place
# json.dump(open(path, "w")) truncates the file before writing the new
# content, so a kill mid-write would leave a corrupt/truncated lock file on
# disk. A temp file in the same directory plus os.replace is atomic on a
# local filesystem: a killed writer leaves, at worst, a stray .tmp.<pid>
# file next to an untouched, still-valid lock file.
#
# `lock_register_handle` deliberately does NOT read-modify-write the lock
# file directly, even though every other lock_* writer below does. Two
# independent read-modify-write processes on the same file (a --persist
# dispatch appending a handle, and a running watchdog refreshing
# heartbeatAt) can race: reader A reads, reader B reads, A writes, B writes
# — B's write wins and silently discards A's change. If that lost update is
# a just-created debater's handle, the watchdog never learns about it and
# can never close it — precisely the orphan this task exists to prevent.
# So instead: lock_register_handle only ever appends one line to a sidecar
# file ("<lock path without .json>.handles.jsonl"); a single `printf >>`
# write of one short line is atomic on a local filesystem (POSIX guarantees
# atomicity for writes at or below PIPE_BUF, at least 512 bytes — far more
# than one terminal handle), so any number of concurrent appends can never
# clobber each other. The watchdog (the lock file's sole read-modify-write
# owner after the initial lock_write) folds the sidecar into the lock's
# "handles" array on every poll cycle via lock_merge_and_refresh, then
# empties the sidecar. This composition (many safe appenders, one
# periodic-merging owner) avoids the race without needing a real mutex —
# bash 3.2 / macOS has no `flock(1)`.
lock_write() {
  # $1=path $2=pid $3=slug $4=ttl_seconds. Creates (or overwrites) the lock
  # with an empty handles array; handles arrive later via
  # lock_register_handle as --persist dispatches create them.
  local path="$1" pid="$2" slug="$3" ttl="$4"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  python3 - "$path" "$pid" "$slug" "$ttl" <<'PY'
import json, os, sys, datetime

path, pid, slug, ttl = sys.argv[1:5]
data = {
    "pid": int(pid),
    "slug": slug,
    "handles": [],
    "heartbeatAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "ttlSeconds": int(ttl),
}
tmp_path = path + ".tmp." + str(os.getpid())
with open(tmp_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp_path, path)
PY
}

lock_register_handle() {
  # $1=lock_file $2=handle. See the file-header comment above for why this
  # appends to a sidecar instead of writing the lock file directly. Silent
  # no-op (return 1) if the lock file does not exist — a caller with no
  # active lock context has nothing to register against.
  local lock_file="$1" handle="$2" sidecar
  [[ -n "$lock_file" && -f "$lock_file" ]] || return 1
  sidecar="${lock_file%.json}.handles.jsonl"
  printf '%s\n' "$handle" >> "$sidecar"
}

lock_merge_and_refresh() {
  # $1=lock_file. Folds the append-only sidecar's handles into this lock's
  # own "handles" array (dedup), refreshes heartbeatAt to now, and
  # atomically rewrites the lock file. Truncates the sidecar after a
  # successful merge. Returns 1 (no write attempted) if the lock file
  # itself is missing or unparseable — callers (the watchdog loop) must
  # treat that as "nothing left to own," not as an error to retry past.
  local lock_file="$1" sidecar
  [[ -f "$lock_file" ]] || return 1
  sidecar="${lock_file%.json}.handles.jsonl"
  python3 - "$lock_file" "$sidecar" <<'PY'
import json, os, sys, datetime

lock_path, sidecar_path = sys.argv[1:3]
try:
    d = json.load(open(lock_path))
except Exception:
    sys.exit(1)

handles = list(d.get("handles") or [])
seen = set(handles)
if os.path.exists(sidecar_path):
    with open(sidecar_path) as f:
        for line in f:
            h = line.strip()
            if h and h not in seen:
                handles.append(h)
                seen.add(h)

d["handles"] = handles
d["heartbeatAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()

tmp_path = lock_path + ".tmp." + str(os.getpid())
with open(tmp_path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp_path, lock_path)

if os.path.exists(sidecar_path):
    open(sidecar_path, "w").close()
PY
}

lock_pid() {
  # $1=path -> owning pid on stdout (empty if missing/malformed). Meant to
  # be captured via `$(lock_pid ...)` by callers, so — following the same
  # precaution documented at length in create_role above — the python
  # heredoc below redirects its own stdout to a scratch file (plain `>`,
  # never nested inside this function's own `$(...)`), and a separate
  # trivial, heredoc-free `cat` is what the caller's command substitution
  # actually captures.
  local path="$1" scratch
  scratch="$(mktemp)"
  python3 - "$path" <<'PY' >"$scratch"
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
    print(d.get("pid") or "")
except Exception:
    print("")
PY
  cat "$scratch"
  rm -f "$scratch"
}

lock_handles() {
  # $1=path -> each handle on its own line (empty output if missing/
  # malformed). Same scratch-file precaution as lock_pid.
  local path="$1" scratch
  scratch="$(mktemp)"
  python3 - "$path" <<'PY' >"$scratch"
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
for h in d.get("handles") or []:
    print(h)
PY
  cat "$scratch"
  rm -f "$scratch"
}

lock_is_fresh() {
  # $1=path -> exit 0 (fresh: heartbeatAt within ttlSeconds of now) or 1
  # (stale, missing, or malformed). Bare exit-code contract, never
  # `$(...)`-captured, so this is safe as a plain heredoc regardless of the
  # bash-3.2-heredoc-in-$(...) issue documented elsewhere in this file.
  #
  # This is the primitive Task 3's concurrency refusal must call: before a
  # new debate driver writes its own lock, enumerate every OTHER file under
  # `$ORCH/debate-locks/*.json` (slug = basename minus .json), call
  # `lock_is_fresh` on each, and refuse to start if any of them is fresh
  # AND names a different slug than the one about to be started (use
  # `lock_pid` to name the owning pid in the refusal message).
  local path="$1"
  [[ -f "$path" ]] || return 1
  python3 - "$path" <<'PY'
import json, sys, datetime

path = sys.argv[1]
try:
    d = json.load(open(path))
    hb = datetime.datetime.fromisoformat(d["heartbeatAt"])
    ttl = float(d["ttlSeconds"])
except Exception:
    sys.exit(1)
if hb.tzinfo is None:
    hb = hb.replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
age = (now - hb).total_seconds()
sys.exit(0 if age < ttl else 1)
PY
}

lock_remove() {
  # $1=lock_file. Removes the lock and its sidecar (if any). Idempotent —
  # always safe to call on a lock that is already gone or never existed.
  local path="$1"
  rm -f "$path" "${path%.json}.handles.jsonl" 2>/dev/null || true
}

lock_handle_claimed_elsewhere() {
  # $1=locks_dir $2=handle $3=exclude_lock_file -> exit 0 if some OTHER lock
  # file in locks_dir claims $2 (in its merged "handles" array OR its
  # not-yet-merged sidecar — a handle a --persist dispatch just registered
  # can sit in the sidecar for up to one whole poll cycle before that lock's
  # own watchdog folds it in, and reading only "handles" would wrongly say
  # "not claimed" during that window) AND we cannot prove that other lock's
  # recorded owner pid is gone; exit 1 only once EVERY lock naming the
  # handle has a confirmed-dead owner.
  #
  # Two different roles reuse the SAME underlying terminal handle for a
  # role key across debates (ensure_terminal reuses a live role terminal
  # globally), so two different debates can legitimately share one
  # debater's handle, each having registered it into its own lock. Before
  # closing a handle, a caller must check whether some OTHER lock still
  # actively depends on it.
  #
  # Deliberately NOT gated on lock_is_fresh: a lock's own watchdog can die
  # (or fall behind) independently of its OWNER (driver) staying alive and
  # actively using the handle — checking freshness first would skip
  # exactly that lock without ever looking at its owner, treating a still
  # -live owner's claim as if it did not exist. The owner pid is checked
  # directly instead, with the same "never treat an inability to
  # determine liveness as license to act" bias as pid_alive() on the
  # python/sweep side: an empty or unreadable owner pid can never be
  # PROVEN dead, so it defaults to protecting too.
  #
  # This function's own `for` loop already scans every lock in locks_dir
  # and only `return`s early on a live claim, so it does not stop at the
  # first lock that merely names the handle — a related, separate bug
  # found in the same review DOES exist, but on the python/sweep side
  # (orca-sweep-orphans.sh's stale_candidates dict kept only the first
  # stale lock naming a given handle, so sort order could decide
  # protection there); fixed at that site to aggregate the same way this
  # loop always has. A handle is protected if ANY lock naming it has an
  # owner that is not provably dead; only when every lock naming it has a
  # confirmed-dead owner does this return "not claimed", allowing the
  # caller to proceed.
  #
  # This does not reopen the mutual-deference gap fixed in the previous
  # round (two locks sharing a handle, both owners die near-simultaneously,
  # each lock's watchdog defers to the other because the other still LOOKS
  # fresh — heartbeatAt does not expire until a full ttlSeconds after the
  # last refresh, which can be tens of minutes even though the owner died
  # seconds ago). Freshness plays no part in this decision at all now: the
  # only way a lock counts as "claiming" is a NOT-provably-dead owner pid.
  # Once an owner is confirmed dead (kill -0 fails with no such process),
  # it stays dead — there is no path back to "alive" — so once BOTH
  # owners in a shared-handle pair are confirmed dead, BOTH sides' checks
  # of each other correctly resolve to "not claimed", and whichever
  # watchdog runs its close phase proceeds instead of deferring. Verified
  # both analytically and empirically (W5 in tests/debate.sh, and the W6
  # matrix added for this fix: both-dead / one-alive / both-alive).
  local locks_dir="$1" handle="$2" exclude="$3" lf sidecar other_pid claims
  for lf in "$locks_dir"/*.json; do
    [[ -f "$lf" ]] || continue
    [[ -n "$exclude" && "$lf" == "$exclude" ]] && continue

    claims=1
    if lock_handles "$lf" | grep -qxF "$handle"; then
      claims=0
    else
      sidecar="${lf%.json}.handles.jsonl"
      if [[ -f "$sidecar" ]] && grep -qxF "$handle" "$sidecar"; then
        claims=0
      fi
    fi
    [[ "$claims" -eq 0 ]] || continue

    other_pid="$(lock_pid "$lf")"
    if [[ -z "$other_pid" ]] || kill -0 "$other_pid" 2>/dev/null; then
      return 0
    fi
    # This one lock's owner is confirmed dead — keep scanning the rest;
    # do NOT return 1 here (that is exactly the "stop at the first claim"
    # bug this fix closes).
  done
  return 1
}
