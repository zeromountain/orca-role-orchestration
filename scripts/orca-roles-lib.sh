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
  local title="$1" command="$2" json handle
  echo "→ Creating $title" >&2
  json="$(orca terminal create --worktree "$WORKTREE" --title "$title" --command "$command" --json)"
  handle="$(printf '%s' "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
r=d.get("result") or d
h=r.get("handle") or (r.get("terminal") or {}).get("handle") or d.get("handle")
if not h:
    raise SystemExit("no handle in terminal create response")
print(h)
')"
  orca terminal rename --terminal "$handle" --title "$title" --json >/dev/null 2>&1 || true
  echo "  handle=$handle" >&2
  printf '%s\n' "$handle"
}

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
  local handle="$1" role="$2" model="$3" fallback_body="$4" body
  if body="$(persona_body "$role")" && [[ -n "${body// }" ]]; then
    : # use full persona file
  else
    body="$fallback_body"
  fi
  orca terminal send --terminal "$handle" --text "$(seed_text "$role" "$model" "$body")" --enter --json >/dev/null
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
  # $1=handle → 0 if present & connected in terminal list
  orca terminal list --json 2>/dev/null | python3 -c '
import json, sys
h = sys.argv[1]
ts = (json.load(sys.stdin).get("result") or {}).get("terminals") or []
sys.exit(0 if any(t.get("handle") == h and t.get("connected") for t in ts) else 1)
' "$1"
}

ensure_terminal() {
  # $1=role → guaranteed-live handle on stdout
  local role="$1" handle title model agent
  handle="$(handles_get "$HANDLES_FILE" "$role")"
  if [[ -n "$handle" ]] && terminal_is_live "$handle"; then
    printf '%s\n' "$handle"
    return 0
  fi
  if [[ -n "$handle" ]]; then
    echo "Role $role handle $handle is dead/missing — recreating…" >&2
  else
    echo "Role $role has no handle — creating…" >&2
  fi
  IFS=$'\t' read -r title model agent < <(role_meta "$role")
  handle="$(create_role "$title" "$(role_launch_cmd "$role")")"
  wait_idle "$handle"
  seed "$handle" "$role" "$model" "$(role_fallback_body "$role")"
  handles_set "$HANDLES_FILE" "$role" "$handle"
  printf '%s\n' "$handle"
}
