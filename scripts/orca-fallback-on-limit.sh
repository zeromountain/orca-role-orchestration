#!/usr/bin/env bash
# Failover primary role → Antigravity Gemini 3.5 Flash (Medium).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
HANDLES_FILE="$ORCH/handles.json"
DISPATCH="$HERE/orca-dispatch-role.sh"
FROM=""
SPEC=""
SPEC_FILE=""
CHECK_ONLY=0
LIMIT_RE='session limit|rate limit|usage limit|overloaded|quota exceeded|try again later|\b429\b|hit your limit|capacity'

usage() {
  cat <<'EOF'
Usage:
  orca-fallback-on-limit.sh --from <architect|executor|thrifty|term_*> --spec "..."
  orca-fallback-on-limit.sh --from <role|handle> --spec-file file.md
  orca-fallback-on-limit.sh --check-handle <term_*>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) FROM="${2:?}"; shift 2 ;;
    --spec) SPEC="${2:?}"; shift 2 ;;
    --spec-file) SPEC_FILE="${2:?}"; shift 2 ;;
    --check-handle) FROM="${2:?}"; CHECK_ONLY=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$FROM" ]]; then usage; exit 1; fi

resolve_handle() {
  local key="$1"
  if [[ "$key" == term_* ]]; then printf '%s' "$key"; return; fi
  if [[ ! -f "$HANDLES_FILE" ]]; then
    echo "Missing $HANDLES_FILE — run bootstrap first" >&2
    exit 1
  fi
  python3 - "$HANDLES_FILE" "$key" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
role=sys.argv[2]
h=(d.get("roles") or {}).get(role, {}).get("handle") or d.get(role)
if not h:
    raise SystemExit(f"no handle for {role}")
print(h)
PY
}

preview_limited() {
  local handle="$1" preview
  preview="$(orca terminal show --terminal "$handle" --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
r=d.get("result") or d
t=r.get("terminal") or r
print(t.get("preview") or "")
' 2>/dev/null || true)"
  printf '%s' "$preview" | grep -Eiq "$LIMIT_RE"
}

HANDLE="$(resolve_handle "$FROM")"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if preview_limited "$HANDLE"; then echo "LIMITED: $HANDLE"; exit 0; fi
  echo "OK: $HANDLE (no limit pattern in preview)"; exit 1
fi

if [[ -n "$SPEC_FILE" ]]; then SPEC="$(cat "$SPEC_FILE")"; fi
if [[ -z "${SPEC// }" ]]; then echo "--spec or --spec-file required" >&2; exit 1; fi

if [[ ! -f "$HANDLES_FILE" ]] || ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if (d.get("roles") or {}).get("fallback",{}).get("handle") or d.get("fallback") else 1)
' "$HANDLES_FILE" 2>/dev/null; then
  echo "No fallback handle — creating role-agy-fallback…"
  WT="$(python3 - "$HANDLES_FILE" <<'PY' 2>/dev/null || echo active
import json
import sys

with open(sys.argv[1]) as stream:
    print(json.load(stream).get("worktree", "active"))
PY
)"
  CREATE="$(orca terminal create --worktree "$WT" --title "role-agy-fallback" \
    --command 'agy --model "Gemini 3.5 Flash (Medium)" --dangerously-skip-permissions' --json)"
  FB="$(printf '%s' "$CREATE" | python3 -c '
import json,sys
d=json.load(sys.stdin); r=d.get("result") or d
print(r.get("handle") or (r.get("terminal") or {}).get("handle") or "")
')"
  orca terminal rename --terminal "$FB" --title "role-agy-fallback" --json >/dev/null 2>&1 || true
  python3 - "$HANDLES_FILE" "$FB" <<'PY'
import json,sys,datetime,os
path, fb = sys.argv[1:3]
d=json.load(open(path)) if os.path.exists(path) else {}
d.setdefault("roles", {})
d["fallback"]=fb
d["roles"]["fallback"]={
  "handle": fb, "title": "role-agy-fallback",
  "model": "Gemini 3.5 Flash (Medium)", "agent": "antigravity", "cli": "agy",
}
d["limit_failover"]={
  "enabled": True, "target_role": "fallback",
  "model": "Gemini 3.5 Flash (Medium)",
  "script": "./scripts/orca-fallback-on-limit.sh",
}
d["updatedAt"]=datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(path,"w") as f:
    json.dump(d,f,indent=2); f.write("\n")
print("fallback handle:", fb)
PY
fi

if preview_limited "$HANDLE"; then
  echo "Detected limit on $HANDLE — failing over to agy Gemini 3.5 Flash (Medium)"
else
  echo "No explicit limit pattern; failing over as requested"
fi

FULL_SPEC="$(cat <<EOF
[FAILOVER from $FROM / $HANDLE]
Primary agent hit rate/session limit or was manually failed over.
Continue with Gemini 3.5 Flash (Medium). Prefer finishing over redesign.
Follow project AGENTS.md / CLAUDE.md constraints if present.

TASK:
$SPEC
EOF
)"

"$DISPATCH" fallback --spec "$FULL_SPEC"
echo "Failover dispatched to ROLE=fallback."
echo "Wait: orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 900000 --json"
