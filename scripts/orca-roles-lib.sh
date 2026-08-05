#!/usr/bin/env bash
# Shared helpers for role bootstrap / dispatch / close.
# Sourced only — do not execute. No set -e here (callers own shell options).
# Single source for role launch strings (not roles.yaml).

role_overrides() {
  # $1=role → title\x1f model\x1f agent\x1f launch_command, empty where unset.
  # Optional user-owned .orca/orchestration/roles.local.json, e.g.
  #   {"thrifty": {"model": "claude-sonnet-5",
  #                "launch_command": "claude --model claude-sonnet-5 …"}}
  # JSON, not YAML: there is no YAML parser in this package by design.
  # Role NAMES stay fixed at four; only their bindings are overridable.
  local f="${ORCH:-.}/roles.local.json"
  if [[ ! -f "$f" ]]; then
    printf '\037\037\037\n'
    return 0
  fi
  python3 - "$f" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as stream:
        d = json.load(stream)
except Exception:
    print("\x1f\x1f\x1f")
    raise SystemExit(0)
role = (d.get(sys.argv[2]) or {}) if isinstance(d, dict) else {}
if not isinstance(role, dict):
    role = {}
fields = [role.get(k) or "" for k in ("title", "model", "agent", "launch_command")]
# \x1f (unit separator): a NON-whitespace delimiter, so bash `read` keeps empty
# fields in place instead of collapsing them.
print("\x1f".join(str(f).replace("\x1f", " ").replace("\n", " ") for f in fields))
PY
}

role_meta() {
  # $1=role → title<TAB>model<TAB>agent. The single source for role bindings.
  local title model agent o_title o_model o_agent o_cmd
  case "$1" in
    architect) title="role-opus-architect"; model="claude-opus-4-8"; agent="claude" ;;
    executor)  title="role-sol-executor";   model="gpt-5.6-sol";     agent="codex" ;;
    thrifty)   title="role-grok-thrifty";   model="grok-4.5";        agent="grok" ;;
    fallback)  title="role-agy-fallback";   model="Gemini 3.5 Flash (Medium)"; agent="antigravity" ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
  IFS=$'\037' read -r o_title o_model o_agent o_cmd < <(role_overrides "$1")
  [[ -n "${o_title// }" ]] && title="$o_title"
  [[ -n "${o_model// }" ]] && model="$o_model"
  [[ -n "${o_agent// }" ]] && agent="$o_agent"
  printf '%s\t%s\t%s\n' "$title" "$model" "$agent"
}

role_launch_cmd() {
  # $1=role → CLI launch command string
  local cmd o_title o_model o_agent o_cmd
  case "$1" in
    architect)
      cmd='claude --model claude-opus-4-8 --dangerously-skip-permissions'
      ;;
    executor)
      cmd='codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox'
      ;;
    thrifty)
      cmd='grok --model grok-4.5 --permission-mode bypassPermissions'
      ;;
    fallback)
      cmd='agy --model "Gemini 3.5 Flash (Medium)" --dangerously-skip-permissions'
      ;;
    *) echo "unknown role: $1" >&2; return 1 ;;
  esac
  IFS=$'\037' read -r o_title o_model o_agent o_cmd < <(role_overrides "$1")
  [[ -n "${o_cmd// }" ]] && cmd="$o_cmd"
  printf '%s\n' "$cmd"
}

role_cli() {
  # $1=role → the executable that must be on PATH for that role to start.
  # Not the same as role_meta's agent field: fallback's agent is "antigravity"
  # but its binary is `agy`. An overridden launch command wins — otherwise
  # preflight would check the default binary a user deliberately replaced.
  local o_title o_model o_agent o_cmd
  IFS=$'\037' read -r o_title o_model o_agent o_cmd < <(role_overrides "$1")
  if [[ -n "${o_cmd// }" ]]; then
    printf '%s\n' "${o_cmd%% *}"
    return 0
  fi
  case "$1" in
    architect) printf 'claude\n' ;;
    executor)  printf 'codex\n' ;;
    thrifty)   printf 'grok\n' ;;
    fallback)  printf 'agy\n' ;;
    *) return 1 ;;
  esac
}

orca_reachable() {
  # Parse the JSON rather than grepping for a literal '"reachable": true' —
  # a whitespace change in the CLI's output would silently read as "down".
  orca status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)


def find(node):
    if isinstance(node, dict):
        if node.get("reachable") is True:
            return True
        return any(find(v) for v in node.values())
    if isinstance(node, list):
        return any(find(v) for v in node)
    return False


raise SystemExit(0 if find(d) else 1)
'
}

handles_set_meta() {
  # $1=handles_file, then top-level k=v pairs (worktree, project, …).
  # Same lock as handles_set so it cannot race the per-role writes.
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import datetime, fcntl, json, os, sys
path = sys.argv[1]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
    d.setdefault("version", 1)
    d.setdefault("roles", {})
    for kv in sys.argv[2:]:
        k, _, v = kv.partition("=")
        d[k] = v
    d["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
PY
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
  # $1=handles_file $2=role $3=handle — update that role's handle (and top-level key).
  # Role metadata comes from role_meta(), the single source; never restate it here.
  local file="$1" role="$2" handle="$3" title model agent cli=""
  IFS=$'\t' read -r title model agent < <(role_meta "$role") || return 1
  [[ "$role" == "fallback" ]] && cli="agy"
  python3 - "$file" "$role" "$handle" "$title" "$model" "$agent" "$cli" <<'PY'
import datetime, fcntl, json, os, sys
path, role, handle, title, model, agent, cli = sys.argv[1:8]

os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
# Lock, then temp+replace: bootstrap, dispatch and fallback all mutate this file
# and a reader must never observe a half-written handles.json.
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        d = {}
    if not isinstance(d, dict):
        d = {}
    d.setdefault("version", 1)
    d.setdefault("roles", {})
    d[role] = handle
    row = {"handle": handle, "title": title, "model": model, "agent": agent}
    if cli:
        row["cli"] = cli
    d["roles"][role] = row
    d["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
print(f"handles_set {role}={handle}", file=sys.stderr)
PY
}

ledger_append() {
  # $1=ledger_file $2..=k=v pairs. Appends one row under the same lock the
  # rewriters take, so an append can never be lost to a concurrent rewrite.
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import datetime, fcntl, json, os, sys
path = sys.argv[1]
row = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    row[k] = v or None
row["dispatchedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    with open(path, "a") as f:
        f.write(json.dumps(row) + "\n")
PY
}

ledger_update() {
  # $1=ledger_file $2=taskId $3..=k=v pairs applied to that task's row.
  # Locked + atomic: one background reaper runs per in-flight dispatch and a
  # coordinator may run wait-done at the same time, so unsynchronised
  # read-modify-write silently drops other tasks' rows.
  local file="$1" task="$2"
  shift 2
  [[ -f "$file" ]] || return 0
  python3 - "$file" "$task" "$@" <<'PY'
import datetime, fcntl, json, os, sys
path, task = sys.argv[1:3]
updates = {}
for kv in sys.argv[3:]:
    k, _, v = kv.partition("=")
    updates[k] = v
with open(path + ".lock", "a+") as lk:
    fcntl.flock(lk, fcntl.LOCK_EX)
    rows = []
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
                if row.get("taskId") == task:
                    row.update(updates)
                    row["updatedAt"] = datetime.datetime.now(
                        datetime.timezone.utc
                    ).isoformat()
                rows.append(row)
    except FileNotFoundError:
        rows = []
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    os.replace(tmp, path)
PY
}

terminal_is_live() {
  # $1=handle → 0 live, 1 confirmed gone, 2 UNKNOWN (daemon down / unparseable).
  # The 1-vs-2 split matters: collapsing them makes a daemon hiccup look like
  # "already gone", which leaks the terminal in the reaper and creates a
  # duplicate one in ensure_terminal.
  local out
  out="$(orca terminal list --json 2>/dev/null)" || return 2
  [[ -n "${out// }" ]] || return 2
  printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(2)
ts = (d.get("result") or {}).get("terminals")
if ts is None:
    raise SystemExit(2)
h = sys.argv[1]
raise SystemExit(0 if any(t.get("handle") == h and t.get("connected") for t in ts) else 1)
' "$1"
}

terminal_liveness() {
  # $1=handle → same codes as terminal_is_live, but retries an UNKNOWN result
  # before reporting it. Used where guessing wrong is expensive (ensure_terminal
  # would otherwise create a second terminal for a role that already has one).
  local h="$1" i rc
  for i in 1 2 3; do
    terminal_is_live "$h"
    rc=$?
    [[ "$rc" -eq 2 ]] || return "$rc"
    [[ "$i" -lt 3 ]] && sleep 1
  done
  return 2
}

close_terminal() {
  # $1=handle → 0 closed, 1 confirmed already gone, 2 close FAILED.
  # Single copy — reaper, wait-done and close-role all route through here.
  local h="$1" rc
  if [[ -z "${h// }" || "$h" != term_* ]]; then
    return 1
  fi
  terminal_is_live "$h"
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    return 1
  fi
  # rc 0 (live) or 2 (can't tell) → always attempt. A redundant close is free;
  # a skipped close leaks a billable session.
  if orca terminal close --terminal "$h" --tab --json >/dev/null 2>&1 \
    || orca terminal close --terminal "$h" --json >/dev/null 2>&1; then
    return 0
  fi
  return 2
}

ensure_terminal() {
  # $1=role → guaranteed-live handle on stdout
  local role="$1" handle title model agent rc
  handle="$(handles_get "$HANDLES_FILE" "$role")"
  if [[ -n "$handle" ]]; then
    terminal_liveness "$handle"
    rc=$?
    case "$rc" in
      0)
        printf '%s\n' "$handle"
        return 0
        ;;
      2)
        # Never create a second terminal for a role on a guess — that orphans
        # the live one. Fail loudly instead; the caller can retry.
        echo "Role $role: cannot determine whether $handle is live (Orca unreachable?)." >&2
        echo "  Refusing to create a duplicate. Check: orca status --json" >&2
        return 1
        ;;
    esac
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
