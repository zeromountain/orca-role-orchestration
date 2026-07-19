#!/usr/bin/env bash
# Shared helpers for role bootstrap / dispatch / close.
# Sourced only — do not execute. No set -e here (callers own shell options).
# Single source for role launch strings (not roles.yaml).

role_meta() {
  # $1=role → title<TAB>model<TAB>agent
  case "$1" in
    architect) printf '%s\t%s\t%s\n' "role-opus-architect" "claude-opus-4-8" "claude" ;;
    executor)  printf '%s\t%s\t%s\n' "role-sol-executor"   "gpt-5.6-sol"     "codex" ;;
    thrifty)   printf '%s\t%s\t%s\n' "role-grok-thrifty"   "grok-4.5"        "grok" ;;
    fallback)  printf '%s\t%s\t%s\n' "role-agy-fallback"   "Gemini 3.5 Flash (Medium)" "antigravity" ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
}

role_launch_cmd() {
  # $1=role → CLI launch command string
  case "$1" in
    architect)
      printf '%s\n' 'claude --model claude-opus-4-8 --dangerously-skip-permissions'
      ;;
    executor)
      printf '%s\n' 'codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox'
      ;;
    thrifty)
      printf '%s\n' 'grok --model grok-4.5 --permission-mode bypassPermissions'
      ;;
    fallback)
      printf '%s\n' 'agy --model "Gemini 3.5 Flash (Medium)" --dangerously-skip-permissions'
      ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
}

role_fallback_body() {
  case "$1" in
    architect) printf '%s\n' "Own architecture, judgment, high-risk review, long-horizon plans. Prefer plans/reviews over bulk implementation." ;;
    executor)  printf '%s\n' "Own hard implementation, terminal loops, verification, final integration. Execute approved plans end-to-end." ;;
    thrifty)   printf '%s\n' "Own small tickets, maps, research, prototypes, high-volume low-risk edits. Escalate design risk." ;;
    fallback)  printf '%s\n' "Rate/session-limit safety net. Continue interrupted tasks with smallest viable progress." ;;
    *) return 1 ;;
  esac
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

seed() {
  local handle="$1" role="$2" model="$3" fallback_body="$4" body
  if body="$(persona_body "$role")" && [[ -n "${body// }" ]]; then
    : # use full persona file
  else
    body="$fallback_body"
  fi
  orca terminal send --terminal "$handle" --text "$(cat <<EOF
You are ROLE=$role on model $model in an Orca multi-agent setup for ${PROJECT_NAME:-project}.

$body

Project constraints:
${CONSTRAINTS:-Follow repository conventions; never commit secrets.}
Never commit secrets (.env, keys, *.pem).
Model disagreement → project SSOT docs + current code win.

When you receive an Orca orchestration dispatch preamble, follow it exactly and send worker_done once with taskId+dispatchId.
End of task (automatic close): after worker_done, immediately run
  orca terminal close --terminal <YOUR_HANDLE> --tab --json
using the handle given in the dispatch AUTO-CLOSE block. Then stop — no polling, no check loop.
A background reaper also closes the tab; self-close is belt-and-suspenders.
Until a dispatch arrives, acknowledge role and wait.
EOF
)" --enter --json >/dev/null
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
    "architect": {"title": "role-opus-architect", "model": "claude-opus-4-8", "agent": "claude"},
    "executor":  {"title": "role-sol-executor",   "model": "gpt-5.6-sol",     "agent": "codex"},
    "thrifty":   {"title": "role-grok-thrifty",   "model": "grok-4.5",        "agent": "grok"},
    "fallback":  {
        "title": "role-agy-fallback",
        "model": "Gemini 3.5 Flash (Medium)",
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
