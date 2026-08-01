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
  # $1=handle  $2=close|persist  $3=run_id (optional)
  local handle="$1" mode="${2:-close}" run_id="${3:-}"

  # Run scope for the WORKER's own outbound calls.
  #
  # Orca generates the dispatch preamble, and its `orca orchestration send`
  # example carries no --run. A worker that copies it verbatim — exactly what
  # the preamble instructs — has worker_done refused with legacy_read_only,
  # because the worker's terminal is not bound to a Run either.
  #
  # Measured live: a probe worker completed its task and reported
  # "outcome=succeeded ... Note: orchestration send worker_done blocked by
  # legacy_read_only process identity from this terminal."
  #
  # The coordinator-side fix (resolve_run_id + --run on task-create/dispatch)
  # does NOT cover this — the send originates in the worker's terminal, so the
  # flag has to reach it as an instruction. Without this block every --wait
  # dispatch times out, and every debate round forfeits workers that did the
  # work and had no way to say so.
  local run_scope=""
  if [[ -n "$run_id" ]]; then
    run_scope="
RUN SCOPE (required — the command block above is incomplete without it):
Add --run ${run_id} to EVERY 'orca orchestration' command you run, including
worker_done and heartbeats. The preamble's examples omit it; sent without it,
your messages are refused (legacy_read_only) and the coordinator never sees
them, no matter how well the task itself went. For example:
  orca orchestration send --run ${run_id} --from ${handle} \\
    --type worker_done --subject \"…\" --body \"…\" --outcome succeeded
"
  fi

  if [[ "$mode" == "persist" ]]; then
    cat <<EOF
${run_scope}
STAY-OPEN (required):
After you send worker_done exactly once, do NOT close this terminal and do NOT
run any close command. Stay idle and wait for the next dispatch in this debate.
Do not poll orchestration.
Your Orca terminal handle for this session is: ${handle}
The debate driver closes this tab when the debate ends.
EOF
  else
    cat <<EOF
${run_scope}
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

codex_trust_ensure() {
  # $1 = absolute project path. Idempotently records it as a trusted project
  # in ${CODEX_HOME:-$HOME/.codex}/config.toml. Silent no-op if already there.
  #
  # THE DEFECT THIS FIXES: a codex seat launched in a directory codex has not
  # been told to trust boots into a modal "Do you trust the contents of this
  # directory?" prompt and stops on it. The seat then receives its seed INTO
  # that dialog and produces nothing — observed live as "the codex seat is the
  # only one that never returns", across every debate run. Confirmed by
  # reading the seat's own screen both ways: with this entry present codex
  # boots through to its real prompt (model/directory/permissions banner);
  # without it the dialog is still on screen for the whole readiness window.
  #
  # WHY THE CONFIG FILE AND NOT A FLAG: `-c projects."<path>".trust_level=
  # "trusted"` was tried first and does NOT suppress the dialog, even though
  # the override parses cleanly and reaches codex as a correctly quoted single
  # argv entry (verified). codex evidently honours trust only from persisted
  # config — a defensible design, since a flag that could grant trust to its
  # own invocation would defeat the prompt entirely. So writing the file is
  # the only lever, and this is byte-identical to what codex itself writes
  # when a human answers "Yes, continue" once.
  #
  # LIMITATION: the path recorded is the project root this scaffold is
  # installed into. A seat created against a --worktree selector that Orca
  # resolves OUTSIDE that root would still see the dialog; the seat's own
  # resolved cwd is not known here without a runtime call, and this library
  # is deliberately runtime-free apart from the explicit `orca` calls.
  local root="${1:-}"
  [[ -n "$root" ]] || return 0
  python3 - "${CODEX_HOME:-$HOME/.codex}/config.toml" "$root" <<'PY' || true
import os, shutil, sys, tempfile

cfg, root = sys.argv[1], sys.argv[2]
header = '[projects."%s"]' % root.replace("\\", "\\\\").replace('"', '\\"')

existing = ""
if os.path.exists(cfg):
    with open(cfg, encoding="utf-8") as fh:
        existing = fh.read()

# Textual header match, deliberately not a TOML parse: this has to run on
# whatever python3 the machine ships (tomllib is 3.11+), and it must never
# rewrite a config it does not fully understand. Append-only, never edits or
# reorders anything already in the file.
if any(line.strip() == header for line in existing.splitlines()):
    raise SystemExit(0)

sep = "" if not existing else ("\n" if existing.endswith("\n") else "\n\n")
merged = existing + sep + header + '\ntrust_level = "trusted"\n'

d = os.path.dirname(cfg) or "."
os.makedirs(d, exist_ok=True)
# Temp-then-replace, the same discipline the ledger writers use: a kill part
# way through must never leave the user with a truncated codex config.
fd, tmp = tempfile.mkstemp(dir=d, prefix=".config.toml.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(merged)
    if existing:
        shutil.copymode(cfg, tmp)
    os.replace(tmp, cfg)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("codex trust: registered %s in %s" % (root, cfg), file=sys.stderr)
PY
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
  # Must happen BEFORE the terminal exists: the trust dialog is drawn at codex
  # boot, so registering afterwards would not help this seat. Gated on the
  # command's first token so it only ever fires for codex seats — and this is
  # the single choke point every seat goes through (orca-bootstrap-roles.sh's
  # own loop and ensure_terminal both call create_role), which is why it lives
  # here rather than in either caller.
  case "$command" in
    codex|codex\ *)
      if [[ -n "${ORCH:-}" && -d "$ORCH/../.." ]]; then
        codex_trust_ensure "$(cd "$ORCH/../.." && pwd)"
      fi
      ;;
  esac
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
# Fix round 3: a BUSY verdict (see _terminal_ready_check) extends the poll
# deadline instead of counting against it — a model mid-response to the
# seed's own role-acknowledgment request can legitimately take "tens of
# seconds", more for a high-effort model — but the extension is bounded by
# this ceiling (measured from the very first poll, never renewed past it),
# so a screen that shows busy-shaped text forever still eventually times
# out rather than blocking indefinitely. An estimate, not a measurement —
# no live timing data exists yet for how long a real seed ack can run.
: "${ROLE_BUSY_TIMEOUT_SECONDS:=300}"
# Fix round 4: how many CONSECUTIVE polls must see the same (normalized)
# screen, with tui-idle also holding on the most recent check, before
# terminal_wait_ready's stability path (see its own comment) promotes an
# otherwise-unmatched screen to READY. 3 requires roughly 3 x
# ROLE_READY_POLL_INTERVAL_SECONDS of confirmed staticness — long enough
# that a single lucky coincidence can't trigger it, short enough not to
# add much latency once a seat genuinely has gone idle.
: "${ROLE_READY_STABLE_POLLS:=3}"

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
import json, re, sys

handle, cli, raw = sys.argv[1], sys.argv[2], sys.argv[3]


def emit(verdict, lines):
    print(verdict)
    for ln in lines:
        print(ln)


try:
    d = json.loads(raw) if raw.strip() else None
except Exception:
    d = None

# Fix round 4: every NOT_READY reason below now carries a parenthetical
# sub-tag right after "NOT_READY" -- (unreadable)/(status)/(blank)/
# (vetoed)/(no-match) -- so terminal_wait_ready's bash loop can tell these
# apart with a plain prefix match instead of pattern-matching English
# phrasing. Only ONE sub-case, (no-match), is ever eligible for the new
# stability-based promotion to READY below; the tag is what lets the loop
# apply that promotion to exactly that case and nothing else, most
# importantly never to (vetoed) -- a stable trust dialog or first-run menu
# must keep refusing no matter how long it sits unchanged.
if not isinstance(d, dict) or not d.get("ok"):
    emit(
        "NOT_READY(unreadable): could not read terminal (orca terminal read "
        "failed or returned no output) -- transient, not a verdict on the "
        "screen itself",
        ["(unreadable)"],
    )
    raise SystemExit(0)

term = (d.get("result") or {}).get("terminal")
if not isinstance(term, dict) or term.get("handle") != handle:
    emit(
        "NOT_READY(unreadable): terminal read did not return this handle's "
        "own terminal (structural mismatch) -- transient",
        ["(unreadable)"],
    )
    raise SystemExit(0)

tail = term.get("tail")
if not isinstance(tail, list):
    emit("NOT_READY(unreadable): terminal read returned no tail array -- transient", ["(unreadable)"])
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
    emit(f"NOT_READY(status): terminal status={status!r} -- the CLI process is not running", lines or ["(no output)"])
    raise SystemExit(0)

if not joined.strip():
    emit("NOT_READY(blank): blank screen (no output yet -- CLI still booting)", ["(blank)"])
    raise SystemExit(0)


# Fix round 2 (live verification): a real grok terminal was refused while
# genuinely ready. Its prompt was framed inside a box-drawing border ("  │
# ❯", not "❯" at line start) -- the observed-data table said "'❯' prompt"
# without noting the frame, and round 1 implemented that literally via
# `ln.strip().startswith(needle)`, which a leading "│" defeats (str.strip()
# only removes whitespace, never other characters). Fixed by stripping a
# small, explicit set of leading DECORATION characters -- whitespace plus
# common box-drawing vertical-bar variants -- before checking the prompt
# glyph, repeatedly from the left until nothing more can be stripped (so
# "  │ ❯" reduces to "❯" the same way "  ❯" already did). Applied to every
# CLI's positive check, not just grok's, per the same live-verification
# finding: claude happened to pass live, but nothing about its own pattern
# would have survived the identical framing, and that failure would block
# ordinary dispatch for the six pre-existing roles, not just a debate seat.
_DECORATION_CHARS = " \t│┃║|"


def _strip_leading_decoration(line):
    i = 0
    while i < len(line) and line[i] in _DECORATION_CHARS:
        i += 1
    return line[i:]


def has_prompt_line(needle):
    return any(_strip_leading_decoration(ln).startswith(needle) for ln in lines)


# Fix round 3 (live verification): every failed debate traced to this. The
# gate ran BEFORE seeding (correct) and again before --inject, and in
# between, seeding itself makes the model respond -- the seed text
# explicitly asks it to acknowledge its role. A live grok seat was caught
# doing exactly that ("Thought for 2.1s" / "ROLE=debater_grok -- ready." /
# ... / "Worked for 5.5s") and the inject-side gate refused it: the
# response text interleaves with the prompt frame, so neither the positive
# nor the negative patterns above are a meaningful signal on this screen,
# and treating "no positive match yet" the same as a genuinely stuck
# terminal is wrong -- a model mid-response is not stuck, it is doing what
# was asked. A THIRD verdict, BUSY, is checked BEFORE positive/negative so
# response text is never allowed to accidentally satisfy (a stray "❯"-like
# character in generated prose) or accidentally veto (quoted example text
# happening to contain a trust-dialog phrase) either pattern set --
# `terminal_wait_ready` below treats BUSY as "keep waiting" and extends its
# patience for it, distinctly from both READY and a genuine NOT_READY.
#
# Fix round 4: dropped "Worked for <n>s" from this set. A second live
# grok seat proved it unreliable -- the coordinator's own read of the
# timeline: "Worked for 7.1s" is a COMPLETION notice ("I worked for this
# long [and am now done]"), not evidence of ongoing activity, and it can
# sit statically on screen long after the model has actually finished,
# consuming the entire busy ceiling before the gate finally gave up on a
# seat that had been idle for most of that window. "Thought for <n>s" is
# kept -- round 2's own live evidence showed it as part of an ACTIVELY
# UPDATING status ticker while the model was still visibly writing more
# output afterward, unlike "Worked for", which appeared once, at the end,
# and never changed again. Added "Waiting for respons" (not the full word
# "response" -- the second live capture that motivated this round showed
# it truncated mid-word by the same rendering corruption this round's
# stability fix exists for, "Waiting for respons … 0.0s", so matching the
# stable prefix tolerates that specific corruption instead of silently
# missing it) as a new, unambiguous marker: unlike an elapsed-time report,
# a CLI only shows "waiting for a response" while a response has not yet
# arrived. Both are treated as GENERIC (checked for every CLI) rather than
# grok-only: no other CLI's busy screen has been captured yet (the same
# evidentiary gap as codex's missing positive pattern), but the cost of a
# false match here is bounded and cheap -- waiting somewhat longer before
# the normal not-ready path still applies -- while the cost of NOT
# recognizing a real one is the exact defect this fix exists to close.
# Fix round 5 (whole-branch review, items 3+4): negative-marker matching
# used to substring-match the marker ANYWHERE in the whole ~200-line joined
# tail -- including text the AGENT ITSELF generated (e.g. grok writing "I
# updated the Changelog for v2." in its own response matched the grok-only
# marker 'Changelog'; a claude response merely mentioning "Select a theme"
# in passing matched the generic marker of the same name). Reproduced
# directly against this function pre-fix. Since (vetoed) is excluded from
# the stability-promotion path below by design, this was a hard, permanent
# refusal for that poll cycle -- and it hits the SIX PRE-EXISTING
# PRODUCTION ROLES too, not just debaters (thrifty runs grok in THIS repo,
# whose own vocabulary literally contains "worktree" and "Changelog").
# Fixed the same way the file already reasons about "Quit" below (precision
# over recall for a marker that could plausibly appear in ordinary text):
# anchor each marker to a LINE, not the whole blob, reusing the same
# decoration-stripping already used for positive-prompt matching. A line
# only counts as a veto if its decoration-stripped text STARTS WITH the
# marker -- true for every real dialog/menu line captured live (a menu
# item is a bare whole line, e.g. "New worktree"; a dialog line like "Do
# you trust the files in this folder?" starts with the marker text before
# its own trailing punctuation), false for the marker merely appearing
# mid-sentence in generated prose.
GENERIC_NEGATIVE = [
    # Trust/permission dialogs. Originally documented as "claude-specific";
    # round 2's live verification proved that framing wrong -- a REAL codex
    # seat sat on a directory-trust dialog worded entirely differently
    # ("Do you trust the contents of this directory? Working with
    # untrusted...") from claude's own ("Do you trust the files in this
    # folder"). Genuinely cross-CLI, not a claude quirk, and the stakes are
    # higher for codex specifically than a worse diagnostic: codex has NO
    # positive pattern (see below), so before this marker existed, this
    # exact screen matched no negative marker either and fell through to
    # this function's own "nothing vetoed it -- READY" default for
    # codex -- a genuine false-READY, caught downstream only because that
    # particular seat happened to be a debater_* role whose separate,
    # stricter seed-marker hard gate (see seed()) retried and eventually
    # failed. A pre-existing role on the same CLI (executor launches codex)
    # has no such downstream net -- its marker check is soft/informational
    # by design (Task 2 requirement 4) and would have logged an info line
    # and reported success. Both phrasings are distinctive, multi-word, and
    # not the kind of text a normal ready prompt would ever incidentally
    # contain, so adding the second does not raise false-veto risk.
    "Do you trust the files in this folder",
    "Do you trust the contents of this directory",
    "Select a theme",
]
CLI_NEGATIVE = {
    # Verbatim from the observed-data table. Deliberately EXCLUDES the
    # table's own "Quit" entry: it is a single common word plausibly present
    # in an ordinary ready screen's own footer/hint text (e.g. "ctrl+c to
    # quit"), and the self-review directive here is to bias against
    # misjudging a genuinely ready terminal as not-ready -- precision over
    # recall for this one marker. Round 2's live verification confirmed this
    # directly rather than hypothetically: the real grok seat that exposed
    # the decoration bug above had "Quit" on screen (a leftover first-run
    # menu remnant) at the exact same time as a genuinely working prompt --
    # this marker is also moot regardless, since the positive-before-
    # negative ordering below means it would never be reached once the
    # prompt matches anyway. The other three are multi-word, specific, and
    # were not observed on any ready screen.
    "grok": ["New worktree", "Resume session", "Changelog"],
}


def _line_matches_marker(ln, marker):
    return _strip_leading_decoration(ln).startswith(marker)


def vetoed_reason():
    for marker in GENERIC_NEGATIVE + CLI_NEGATIVE.get(cli, []):
        for ln in lines:
            if _line_matches_marker(ln, marker):
                return marker
    return None


# A codex seat sitting on the directory-trust dialog was still reported
# READY, and the seat then received its seed INTO the modal and produced
# nothing. The anchored matcher above cannot see that screen, for two
# independent reasons, both read straight off a live terminal:
#
#   - `orca terminal read` hands the dialog back with the spaces inside it
#     GONE, so the marker text is not present verbatim to match at all.
#   - What is left arrives as ONE line whose head is the path banner, so the
#     marker is not at the start of it either, and the anchoring the prose
#     false-veto fix introduced (correctly -- see its own comment above)
#     refuses it a second time.
#
# So this second path compares whitespace-removed copies of both sides,
# which drops the anchor. Dropping the anchor alone would resurrect exactly
# the defect that anchoring fixed -- an agent writing the phrase in its own
# prose would veto its seat permanently, since a veto is deliberately not
# stability-promotable. What keeps that from happening is CORROBORATION: a
# line only vetoes here if it ALSO carries a modal's choice affordance.
# Prose can quote the question; it does not come with "1. Yes" attached.
#
# Applies to GENERIC_NEGATIVE (dialogs) only, never CLI_NEGATIVE: menu
# entries like "New worktree" are bare whole lines that the anchored path
# already catches, and they are short enough that a corroborated substring
# match would be a real false-veto risk.
#
# LIMITATION: same line only. A dialog wrapped across two lines by a narrow
# terminal defeats both this and the anchored path. Joining adjacent lines
# before matching was considered and rejected: it widens the false-veto
# surface (any marker line that merely happens to sit next to an affordance
# line would fire), and every capture of this dialog so far collapses onto
# one line rather than wrapping.
def _squash(s):
    return "".join(s.split())


# Fragments, never a whole dialog line. This file is itself read by seats
# working on this repo -- a source line carrying a marker AND an affordance
# together would render on such a seat's screen and veto it. Nothing here,
# or in the fixtures that exercise it, may put both on one physical line.
_DIALOG_AFFORDANCES = ("1.Yes", "2.No", "Pressentertocontinue")


def corroborated_dialog_marker():
    for ln in lines:
        squashed = _squash(_strip_leading_decoration(ln))
        if not any(a in squashed for a in _DIALOG_AFFORDANCES):
            continue
        for marker in GENERIC_NEGATIVE:
            if _squash(marker) in squashed:
                return marker
    return None


# Computed unconditionally, before the busy check below -- see the item-4
# comment there for why this must be independent of (and, when it matches,
# override) a BUSY verdict.
_vetoed_marker = vetoed_reason() or corroborated_dialog_marker()

_BUSY_RE = re.compile(r"\bThought for \d|\bWaiting for respons")


def busy_reason():
    for ln in lines:
        m = _BUSY_RE.search(ln)
        if m:
            return f"BUSY: model is actively responding to the seed ({m.group(0)!r} seen) -- waiting, not refusing"
    return None


# Fix round 5 (item 4): busy_reason() used to run BEFORE the negative-marker
# check and win outright -- BUSY is stability-promotable (see
# terminal_wait_ready's stability path below), so a STATIC trust dialog or
# first-run menu that also happens to contain busy-shaped leftover text
# (e.g. a stale "Thought for 3s" line) got misclassified as BUSY, sat
# unchanging for 3 polls, and was promoted to READY -- directly violating
# the invariant this file states twice: a stable trust dialog or first-run
# menu must keep refusing no matter how long it sits unchanged. Reproduced
# directly pre-fix. _vetoed_marker is now computed independently, above,
# and wins here whenever both match -- BUSY is only ever emitted for a
# screen this function is NOT also vetoing. This does not change ordering
# relative to the positive per-CLI check just below: a genuine positive
# match still wins over a vetoed marker regardless (see the grok
# menu-vs-prompt design decision there), so a real prompt match coexisting
# with both a busy marker and a vetoed marker still reads as READY, not
# BUSY and not vetoed -- stronger evidence (an actual prompt match) outranks
# both (see TR26 in tests/debate.sh, which cements this three-way case).
_busy = busy_reason()
if _busy and not _vetoed_marker:
    emit(_busy, lines)
    raise SystemExit(0)


# Positive per-CLI ready pattern, checked BEFORE negative markers below. See
# the grok row of the observed-data table: its ready prompt "may sit below a
# first-run menu" -- the menu text can be genuinely present on a terminal
# that, right now, is fully able to receive input (confirmed directly, twice
# now: text sent to a grok terminal on this exact screen was accepted and
# answered normally, and a LIVE run refused a real grok seat showing this
# exact combination -- splash art, a "Quit" menu remnant, AND a working
# framed prompt -- before round 2's decoration fix). Vetoing on menu text
# regardless of prompt presence would also risk misjudging `thrifty` (a
# pre-existing PRODUCTION role that launches grok, not a debater) as
# not-ready every time that menu lingers on screen -- exactly the regression
# this task warns against. So a CLI's own positive prompt match, when it
# matches, wins outright; negative markers are only evaluated when the
# positive check does not (yet) confirm readiness.
positive_known = True
if cli == "claude":
    ready = has_prompt_line("❯") and ("bypass permissions on" in joined)
    positive_desc = "'❯' prompt (decoration-tolerant) + 'bypass permissions on' status line"
elif cli == "grok":
    ready = has_prompt_line("❯")
    positive_desc = "'❯' prompt (decoration-tolerant)"
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
    # dispatch. So: banner present -> corroborate with ANY prompt-shaped
    # line (matches the boot sequence verbatim, decoration-tolerant).
    # Banner absent (warm case) -> round 1 required the prompt to be the
    # CURRENT LAST non-blank line, on the theory that position alone could
    # distinguish a real idle prompt from a mid-response markdown
    # blockquote ("> quoted text"). Round 2's live grok evidence overturned
    # that theory: a version-update notice was the terminal's actual last
    # line, AFTER a genuinely working prompt -- a real UI element, not a
    # contrived edge case, that a last-line requirement would misjudge as
    # not-ready. Position was never the right axis; CONTENT is -- a bare
    # prompt (decoration-stripped ">" with nothing but optional trailing
    # whitespace after it) reads as an idle input box regardless of where
    # it sits in the tail, while a blockquote's line has real text after
    # the "> " and is correctly rejected on that basis, not its position.
    def is_agy_prompt_line(ln):
        s = _strip_leading_decoration(ln)
        return s == ">" or s.startswith("> ")

    def is_bare_agy_prompt_line(ln):
        s = _strip_leading_decoration(ln)
        if s == ">":
            return True
        if s.startswith(">"):
            return s[1:].strip() == ""
        return False

    # Note the asymmetry: fresh-boot stays loose (any "> "-prefixed line,
    # not necessarily bare), warm requires bareness. Not an oversight --
    # requiring bareness during boot too risks a DIFFERENT false-not-ready:
    # an idle input box showing inline placeholder text (e.g. "> Type a
    # message") is a plausible real UI, and boot is corroborated by the
    # banner besides, so the extra strictness buys nothing there and could
    # cost a false refusal. The warm case has no such corroboration and is
    # the one actually exposed to blockquote-shaped content (an agent only
    # generates prose, and therefore only risks looking like a blockquote,
    # once it is already past boot and has started responding), so that is
    # where the stricter check earns its keep.
    banner_present = "Antigravity CLI" in joined
    if banner_present:
        ready = any(is_agy_prompt_line(ln) for ln in lines)
    else:
        ready = any(is_bare_agy_prompt_line(ln) for ln in lines)
    positive_desc = (
        "'Antigravity CLI' banner + any '>' prompt line (fresh boot), "
        "or a bare '>' prompt with nothing after it, anywhere in the tail (warm)"
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

# _vetoed_marker was computed above, before the busy check -- see its own
# comment and the item-4 comment above busy_reason() for why. A positive
# match (just above) still wins over it regardless.
if _vetoed_marker:
    emit(f"NOT_READY(vetoed): matched not-ready marker {_vetoed_marker!r} (cli={cli or 'unknown'})", lines)
    raise SystemExit(0)

if positive_known:
    # Fix round 4: this specific sub-case -- a CLI WITH a known positive
    # pattern, whose screen is non-blank, not a bad status, and not vetoed
    # by any negative marker, but still doesn't match -- is the ONLY one
    # terminal_wait_ready's stability path (see its own comment) is allowed
    # to promote to READY, and it recognizes this case by the "(no-match)"
    # tag alone, via a plain prefix match, not by re-deriving "was this
    # actually vetoed" from English phrasing. Keep this exact tag stable.
    emit(f"NOT_READY(no-match): no {cli} ready prompt matched yet (looking for {positive_desc})", lines)
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

_terminal_stability_key() {
  # $1=screen text (the tail dump already captured by the caller — this
  # does NOT re-read the terminal) -> a normalized digest on stdout.
  #
  # Fix round 4: a second live grok seat sat idle at its own acknowledgment
  # ("No dispatch received yet. Standing by for the first round preamble.")
  # for the entire BUSY ceiling before being refused — not because it was
  # actually busy, but because overlapping redraws left a mangled composite
  # frame (a spinner, a stale elapsed-time footer, and box-drawing
  # fragments all interleaved mid-line) that never matched any positive
  # pattern and never presented a clean prompt glyph. No decoration-
  # stripping or pattern refinement can reliably parse a frame that
  # corrupted. What DOES generalize: a genuinely working CLI keeps
  # producing new, different output (spinners tick, counters advance,
  # response text streams); a genuinely idle one, however garbled its
  # frame looks, stops changing. This produces the KEY terminal_wait_ready
  # compares across consecutive polls for that stability signal.
  #
  # Normalizes away exactly what the coordinator named as noise that
  # churns without meaning: braille-pattern spinner glyphs (U+2800-U+28FF,
  # the block used for both animated spinners AND grok's own splash-art
  # ASCII image — irrelevant here, since this key is compared only for
  # equality, never pattern-matched against) and elapsed-time counters
  # shaped like "0.0s" / "7.1s" (digits, optional decimal, a REQUIRED
  # trailing "s" — deliberately not bare digits, to avoid stripping
  # unrelated numeric content and reducing this to a coincidence machine).
  # Whitespace runs are also collapsed, since partial/overlapping redraws
  # can shift horizontal spacing without changing the meaningful content.
  # Hashed (not compared as raw text) purely to keep the bash-side
  # comparison a simple, robust string equality check regardless of what
  # bytes the normalized text happens to contain.
  local text="$1"
  python3 -c '
import hashlib, re, sys

text = sys.argv[1]
text = re.sub(r"[⠀-⣿]", "", text)
text = re.sub(r"\d+(?:\.\d+)?s\b", "", text)
lines = [re.sub(r"\s+", " ", ln).strip() for ln in text.split("\n")]
normalized = "\n".join(lines)
print(hashlib.sha256(normalized.encode("utf-8", "replace")).hexdigest())
' "$text"
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
  # Fix round 3: a BUSY verdict (the model actively responding to the
  # seed's own role-acknowledgment request — see _terminal_ready_check) is
  # neither READY nor a genuine NOT_READY. It extends deadline_epoch out to
  # now + ROLE_READY_TIMEOUT_SECONDS again on every poll that observes it —
  # never past busy_ceiling_epoch, fixed once at the start from
  # ROLE_BUSY_TIMEOUT_SECONDS, so a screen that shows busy-shaped text
  # forever still eventually times out through the normal refusal path
  # below, it just gets a much longer overall allowance than a genuinely
  # stuck screen (booting/trust-dialog/blank/menu) ever does. A poll that
  # observes neither READY nor BUSY does not touch either deadline — the
  # original, tighter ROLE_READY_TIMEOUT_SECONDS budget still governs that
  # case exactly as it did before this round.
  #
  # $3 is a caller-supplied ABSOLUTE epoch, not "elapsed since this call
  # started": ensure_terminal knows a genuine creation timestamp for a
  # terminal it just created and passes created_epoch +
  # ROLE_READY_MIN_ELAPSED_SECONDS. orca-dispatch-role.sh's own gate (now
  # called before task-create, not before --inject — see its own comment)
  # does NOT know a creation time for a handle it merely resolved (it may
  # have just been created moments ago by ensure_terminal above, which
  # already applied this floor once before seeding, or it may be a
  # long-warm terminal from a prior dispatch) and passes no floor at all —
  # restarting a multi-second floor on every ordinary dispatch to an
  # already-ready, already-warm terminal would add pure, unrequested latency
  # to the six pre-existing roles' hot path for no safety benefit.
  #
  # Fix round 4: a STABILITY path to READY, alongside the existing
  # per-CLI positive patterns. A second live grok seat sat idle at its own
  # seed acknowledgment for the entire BUSY window, refused at the ceiling,
  # because overlapping redraws left a mangled composite frame that never
  # cleanly matched any positive pattern (see _terminal_stability_key's own
  # comment). No amount of pattern refinement reliably parses a corrupted
  # frame; what generalizes is that a genuinely working CLI keeps producing
  # DIFFERENT output, while a genuinely idle one — however garbled its
  # frame — stops changing. Eligible for exactly two verdict shapes, both
  # applied inside the loop body below: the "(no-match)" sub-case (a CLI
  # WITH a known positive pattern, non-blank, not a bad status, NOT vetoed
  # by any negative marker, but not matching), AND BUSY — the coordinator's
  # own second capture showed a busy-shaped marker ("Waiting for respons")
  # sitting in a screen that had, per direct diagnosis, already gone idle;
  # text alone cannot reliably tell a stale busy marker from a live one, so
  # stability is the tie-breaker for both, not just one. Never applied to
  # blank, bad-status, unreadable, or, most importantly, a VETOED screen (a
  # stable trust dialog or first-run menu must keep refusing no matter how
  # long it sits unchanged; stability means "not busy", not "ready to
  # work", and the negative checks upstream in _terminal_ready_check remain
  # the sole veto for those). ROLE_READY_STABLE_POLLS consecutive polls
  # with an unchanged normalized screen, AND tui-idle holding on the most
  # recent check (checked directly now instead of discarded via `|| true`),
  # promotes that poll to READY. A reason change to anything ineligible
  # resets the streak — this is about the CURRENT screen being settled, not
  # merely "was ever settled".
  local handle="$1" cli="${2:-}" not_before="${3:-0}"
  local deadline_epoch busy_ceiling_epoch busy_deadline now_epoch verdict reason screen
  local stability_key prev_stability_key="" stable_count=0 tui_idle_confirmed=0 tui_idle_rc
  now_epoch="$(date +%s)"
  deadline_epoch=$((now_epoch + ROLE_READY_TIMEOUT_SECONDS))
  busy_ceiling_epoch=$((now_epoch + ROLE_BUSY_TIMEOUT_SECONDS))
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

    if [[ "$reason" == BUSY:* ]]; then
      busy_deadline=$((now_epoch + ROLE_READY_TIMEOUT_SECONDS))
      [[ "$busy_deadline" -gt "$busy_ceiling_epoch" ]] && busy_deadline="$busy_ceiling_epoch"
      [[ "$busy_deadline" -gt "$deadline_epoch" ]] && deadline_epoch="$busy_deadline"
    fi

    # Stability tracking covers BOTH "(no-match)" and BUSY verdicts, not
    # "(no-match)" alone. The coordinator's own second live grok capture is
    # why: its garbled composite frame contains "Waiting for respons",
    # which correctly classifies as BUSY by text — but the coordinator's
    # own diagnosis of that exact screen was that grok had ALREADY
    # finished; the text was stale noise from overlapping redraws, not
    # evidence of ongoing work, and nothing in the text alone can tell the
    # two apart ("pattern matching alone cannot settle this... if you
    # cannot do that reliably, prefer stability over the text"). So a BUSY
    # verdict still extends the deadline above (protecting a genuinely
    # still-generating response, which DOES keep producing different
    # content and therefore never accumulates stability), but if the exact
    # same normalized screen keeps recurring across polls regardless of
    # which of these two verdicts it produced, that repetition is itself
    # the stronger signal — text can lie about stale-vs-live, unchanging
    # content cannot. Never applied to "(vetoed)", "(blank)", "(status)",
    # or "(unreadable)" — those are either a definitive refusal reason
    # (vetoed) or not meaningfully comparable as "settled" at all.
    if [[ "$reason" == "NOT_READY(no-match):"* || "$reason" == BUSY:* ]]; then
      stability_key="$(_terminal_stability_key "$screen")"
      if [[ -n "$prev_stability_key" && "$stability_key" == "$prev_stability_key" ]]; then
        stable_count=$((stable_count + 1))
      else
        stable_count=1
      fi
      prev_stability_key="$stability_key"
      if [[ "$stable_count" -ge "$ROLE_READY_STABLE_POLLS" && "$tui_idle_confirmed" -eq 1 ]] \
        && { [[ "$not_before" -eq 0 ]] || [[ "$now_epoch" -ge "$not_before" ]]; }; then
        return 0
      fi
    else
      stable_count=0
      prev_stability_key=""
    fi

    [[ "$now_epoch" -ge "$deadline_epoch" ]] && break
    tui_idle_rc=0
    orca terminal wait --terminal "$handle" --for tui-idle \
      --timeout-ms "$((ROLE_READY_POLL_INTERVAL_SECONDS * 1000))" --json >/dev/null 2>&1 || tui_idle_rc=$?
    tui_idle_confirmed=0
    [[ "$tui_idle_rc" -eq 0 ]] && tui_idle_confirmed=1
    sleep "$ROLE_READY_POLL_INTERVAL_SECONDS"
  done

  echo "terminal_wait_ready: $handle (cli=${cli:-unknown}) never became ready within ${ROLE_READY_TIMEOUT_SECONDS}s -- last check: $reason" >&2
  echo "----- $handle screen (most recent) -----" >&2
  printf '%s\n' "$screen" >&2
  echo "-----------------------------------------" >&2
  return 1
}

terminal_created_epoch() {
  # $1=handle -> epoch seconds of that handle's create_role journal entry
  # on stdout, or nothing (empty output, exit 0) if not found/unparseable.
  #
  # Fix round 1: seed() (below) needs a creation timestamp for
  # terminal_wait_ready's minimum-elapsed floor, but seed() is called by
  # MORE than one caller — ensure_terminal, which has a creation timestamp
  # readily at hand (it just called create_role itself), and
  # orca-bootstrap-roles.sh, whose create phase does not otherwise expose
  # one to seed() at all (creates happen in one phase, seeds in a later,
  # separate one). Rather than requiring every current and future caller to
  # track and pass its own timestamp, this reads the ONE place create_role
  # already durably records createdAt for every handle it produces, for
  # every caller, unconditionally: terminal-journal.jsonl. A single,
  # caller-agnostic source beats N caller-specific ones.
  #
  # Same scratch-file + plain `cat` precaution as create_role/lock_pid/
  # _terminal_ready_check above (this function's stdout is meant to be
  # captured via `$(...)`).
  local handle="$1" journal_file="${ORCH:-.}/terminal-journal.jsonl" scratch
  [[ -f "$journal_file" ]] || return 0
  scratch="$(mktemp)"
  python3 - "$journal_file" "$handle" >"$scratch" <<'PY'
import json, sys, datetime

path, handle = sys.argv[1], sys.argv[2]

# Scan the whole (append-only) journal and keep the LAST matching row, in
# case a handle were ever reused (not expected in practice -- orca terminal
# create hands back a fresh, effectively-unique handle every time -- but
# "most recent entry wins" is the correct choice if it ever happened, and
# costs nothing when it doesn't).
created_at = None
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if isinstance(row, dict) and row.get("handle") == handle and row.get("createdAt"):
                created_at = row["createdAt"]
except Exception:
    created_at = None

if not created_at:
    raise SystemExit(0)

try:
    dt = datetime.datetime.fromisoformat(created_at)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    pass
PY
  cat "$scratch"
  rm -f "$scratch"
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
  # target that isn't shaped like a real terminal handle, (b) gates on the
  # terminal actually being ready to receive input (see below), (c)
  # requires the send call to structurally report success, (d) confirms
  # the exact handle is still a live, readable terminal right after
  # sending. Any of these failing is echoed to stderr and returns 1 —
  # never swallowed. seed_text's output itself is untouched by any of this
  # (non-debater seed text is byte-frozen).
  local handle="$1" role="$2" model="$3" fallback_body="$4"
  local body text send_json accepted read_ok attempt read_json marker
  local marker_seen marker_read_json
  local cli created_epoch not_before

  case "$handle" in
    term_*) ;;
    *)
      echo "seed: refusing to send — '$handle' is not a term_*-shaped terminal handle (role=$role). This guard exists because an empty/blank --terminal previously fell back to the CLI's active terminal, i.e. a seed misdelivered to an unrelated session." >&2
      return 1
      ;;
  esac

  # Readiness gate (Task 2; moved here in fix round 1). It used to live
  # only in ensure_terminal, called once immediately before ITS OWN call to
  # seed. That left orca-bootstrap-roles.sh — a second, independent caller
  # of seed(), never routed through ensure_terminal — seeding on tui-idle
  # alone: its apparent safety was a timing accident (bootstrap creates all
  # four terminals in one phase, then seeds in a later phase, so the first
  # role created happens to get real boot time before its seed call), not a
  # guarantee, and a single slow boot or new first-run screen would hit
  # exactly the defect that produced five empty debate runs. Living inside
  # seed() itself means ensure_terminal, orca-bootstrap-roles.sh, and any
  # future caller all get it by construction, not by remembering a separate
  # call — ensure_terminal no longer calls terminal_wait_ready itself; see
  # its own comment.
  #
  # The minimum-elapsed floor's creation timestamp comes from
  # terminal_created_epoch (terminal-journal.jsonl), not a caller-supplied
  # value — see that function's own comment for why a single, caller-
  # agnostic source was chosen over asking every caller to track one.
  cli="$(role_meta "$role" | cut -f3)"
  created_epoch="$(terminal_created_epoch "$handle")"
  if [[ -n "$created_epoch" ]]; then
    not_before=$((created_epoch + ROLE_READY_MIN_ELAPSED_SECONDS))
  else
    not_before=0
  fi
  if ! terminal_wait_ready "$handle" "$cli" "$not_before"; then
    echo "seed: $handle (role=$role) never showed a ready screen — refusing to send; see the screen dump above for what to clear by hand." >&2
    return 1
  fi

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
  local role="$1" handle title model agent live_rc=0
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

  IFS=$'\t' read -r title model agent < <(role_meta "$role")
  handle="$(create_role "$title" "$(role_launch_cmd "$role")" "$role")" || {
    echo "ensure_terminal: create_role failed for role=$role — see terminal-journal.jsonl for the raw create response" >&2
    return 1
  }

  # Durable before anything that can fail: a wait_idle timeout, a
  # readiness-gate timeout (now inside seed() itself — see its own
  # comment), or a seed failure below must still leave this handle closable
  # via handles_get → terminal_is_live → close, instead of leaking an
  # untracked bypass-permissions session.
  if ! handles_set "$HANDLES_FILE" "$role" "$handle"; then
    echo "ensure_terminal: handles_set failed to record handle=$handle for role=$role — terminal exists but is NOT durably tracked in $HANDLES_FILE (see terminal-journal.jsonl)" >&2
    return 1
  fi

  wait_idle "$handle"

  # Fix round 1: the readiness gate that used to be called explicitly HERE
  # moved into seed() itself, so orca-bootstrap-roles.sh's direct seed()
  # calls get it too, by construction, instead of relying on every caller
  # to remember a separate gate call (see seed()'s own comment for the
  # full rationale). Calling seed() is sufficient on its own now — do not
  # re-add a gate call here, or every fresh-creation dispatch pays for the
  # readiness classifier twice.
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

lock_leave_as_breadcrumb() {
  # $1=lock_file
  #
  # Task 3: called instead of lock_remove whenever a close could not be
  # CONFIRMED (terminal_close_and_verify returned 1 "still live" or 2
  # "undetermined") — by orca-debate.sh's cleanup() and by
  # orca-sweep-orphans.sh's run_watchdog, the two places that decide "is
  # every handle this lock owns actually gone" before disposing of the
  # lock. Leaving the lock file (and its sidecar — this does NOT call
  # lock_remove or touch the sidecar at all) in place is what lets
  # orca-sweep-orphans.sh's stale-lock path find the handle later; erasing
  # the lock on a clean exit regardless of whether the close actually took
  # is exactly the bug this task closes (observed live: a genuine orphan
  # produced sweep's "candidates=0", because the ONLY two detectors sweep
  # has are "untracked in handles.json" — which a debater handle never is,
  # by design, see orca-close-role.sh's own header comment — and "stale
  # debate lock", which a prematurely-removed lock defeats trivially).
  #
  # Rewrites ONLY ttlSeconds to 0 — pid/slug/handles/heartbeatAt are left
  # exactly as they were (no lock_write, which would also reset "handles"
  # to an empty array and lose exactly the information the breadcrumb
  # exists to preserve). This one-field change is deliberately double
  # duty, not a coincidence: ttlSeconds is read by exactly two consumers
  # (grepped to confirm) — lock_is_fresh (orca-roles-lib.sh, on the
  # do-not-touch list; this function does not modify it, only feeds it a
  # lock whose own ttlSeconds is now 0) and orca-sweep-orphans.sh's own
  # sweep_mode age-vs-ttl comparison — and forcing it to 0 makes BOTH
  # agree the lock is stale immediately, instead of "fresh" for up to a
  # full ttlSeconds (1800s/30min default):
  #   1. orca-sweep-orphans.sh's stale-lock candidate path only inspects a
  #      lock's handles once age>=ttl — with the ORIGINAL ttl left in
  #      place, the very breadcrumb this function exists to create would
  #      stay invisible to the sweeper for up to half an hour.
  #   2. orca-debate.sh's cross-slug concurrency refusal, and its own
  #      same-slug "overwriting a fresh lock" warning, both key off
  #      lock_is_fresh too. An untouched, still-"fresh"-looking breadcrumb
  #      would wrongfully block (or warn about) a DIFFERENT, perfectly
  #      legitimate debate for as long as that TTL window lasts — exactly
  #      the "concurrency refusal must not start refusing legitimate
  #      debates because breadcrumbs accumulate" risk this whole feature
  #      has to hold at the same time as "don't lose the orphan". Forcing
  #      staleness immediately closes that window to (near) zero.
  # heartbeatAt is deliberately left untouched (not zeroed/backdated) —
  # it still records the true last-known-alive moment, which has forensic
  # value and is not needed for either of the two effects above (both are
  # driven by ttlSeconds alone, since age = now - heartbeatAt is always
  # >= 0 for any heartbeatAt not in the future).
  local lock_file="$1"
  [[ -f "$lock_file" ]] || return 0
  python3 - "$lock_file" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(0)
d["ttlSeconds"] = 0
tmp_path = path + ".tmp." + str(os.getpid())
with open(tmp_path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.replace(tmp_path, path)
PY
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

# ---------------------------------------------------------------------------
# Run scope (Orca contract update, 2026-07-31)
#
# Orchestration moved to a Run-scoped model. `task-create`, `dispatch` and
# `check` now need an explicit `--run <run_id>`. Without it they fall back to
# the RETAINED LEGACY COORDINATOR, which is read-only and refuses every
# mutation with:
#
#   {"ok":false,"error":{"code":"legacy_read_only","message":
#    "This retained legacy coordinator could not prove its original process
#     identity. No effects were applied."}}
#
# The failure is quiet in the worst way: no task id is ever produced, so a
# debate round dispatches nothing and every debater forfeits on a timeout that
# looks like a worker problem. Preflight passes first, which hides the cause.
#
# Binding a Run to the terminal is NOT sufficient on its own — verified live:
# `run-current` returned the bound Run while a `--run`-less `task-create` was
# still refused. The flag has to be passed.
#
# Resolution order:
#   1. $ORCA_RUN_ID   — explicit override, wins outright
#   2. `run-current`  — the Run bound to this coordinator terminal
#   3. empty          — pre-update behaviour, unchanged (see the hint below)
#
# Soft-fails to empty on older Orca builds with no `run-current` subcommand,
# so this never turns a working setup into a hard error.
#
# Callers must resolve ONCE and reuse the value: resolving separately per call
# would let a rebinding between task-create and dispatch split one dispatch
# across two Runs.
resolve_run_id() {
  if [[ -n "${ORCA_RUN_ID:-}" ]]; then
    printf '%s' "$ORCA_RUN_ID"
    return 0
  fi
  local raw=""
  raw="$(orca orchestration run-current --json 2>/dev/null)" || return 0
  [[ -n "$raw" ]] || return 0
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
result = payload.get("result") or {}
run = result.get("run") or {}
sys.stdout.write(run.get("id") or "")
' 2>/dev/null || true
}

# Emit a remediation hint when an orchestration mutation was refused for lack
# of a Run scope. Callers pass the raw JSON they got back; a no-op for any
# other failure, so it is safe to call on every error path.
warn_if_legacy_read_only() {
  local raw="${1:-}" what="${2:-The orchestration call}"
  printf '%s' "$raw" | grep -q 'legacy_read_only' || return 0
  {
    echo "$what was refused: orchestration is in legacy READ-ONLY mode."
    echo "No effects were applied and no task id was produced."
    echo
    echo "Orca's Run-scoped orchestration needs an explicit run id. Bind one:"
    echo
    echo "  orca orchestration run-create --objective \"<what this run is for>\" --json"
    echo
    echo "then re-run this command. To reuse an existing Run instead:"
    echo
    echo "  orca orchestration run-list --json      # find the id"
    echo "  orca orchestration run-use --run <id>   # bind this terminal"
    echo "  # or bypass binding entirely: export ORCA_RUN_ID=run_xxxxxxxxxxxx"
  } >&2
}
