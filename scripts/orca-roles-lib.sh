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

  # Soft, best-effort confirmation only: an info note (not a failure) if the
  # seed's own opening marker isn't visible yet — the agent's TUI may have
  # already redrawn past it by the time we read.
  marker="ROLE=$role"
  if ! printf '%s' "$read_json" | grep -qF "$marker"; then
    echo "seed: (info) marker '$marker' not visible yet in $handle's tail — not a failure, TUI may have redrawn already" >&2
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
sys.exit(0 if any(t.get("handle") == h and t.get("connected") for t in terminals) else 1)
' "$handle"
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
        echo "Role $role handle $handle: liveness undetermined (orca terminal list unavailable) — leaving it alone, not recreating" >&2
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

  # Durable before anything that can fail: a wait_idle timeout or a seed
  # failure below must still leave this handle closable via
  # handles_get → terminal_is_live → close, instead of leaking an untracked
  # bypass-permissions session.
  if ! handles_set "$HANDLES_FILE" "$role" "$handle"; then
    echo "ensure_terminal: handles_set failed to record handle=$handle for role=$role — terminal exists but is NOT durably tracked in $HANDLES_FILE (see terminal-journal.jsonl)" >&2
    return 1
  fi

  wait_idle "$handle"

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
