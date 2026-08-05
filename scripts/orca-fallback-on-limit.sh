#!/usr/bin/env bash
# Failover primary role → Antigravity Gemini 3.5 Flash (Medium).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ORCH/../.." && pwd)"
# shellcheck source=orca-roles-lib.sh
source "$HERE/orca-roles-lib.sh"
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

# 0 = fallback handle present, 1 = genuinely absent, 2 = file unreadable.
# Treating 2 as "absent" is what spawns a SECOND role-agy-fallback terminal
# when a reader catches handles.json mid-write.
fallback_state() {
  [[ -f "$HANDLES_FILE" ]] || return 1
  python3 - "$HANDLES_FILE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as stream:
        d = json.load(stream)
except Exception:
    raise SystemExit(2)
if not isinstance(d, dict):
    raise SystemExit(2)
handle = (d.get("roles") or {}).get("fallback", {}).get("handle") or d.get("fallback")
raise SystemExit(0 if handle else 1)
PY
}

fallback_state
FB_STATE=$?
if [[ "$FB_STATE" -eq 2 ]]; then
  echo "ERROR: $HANDLES_FILE exists but is not readable JSON." >&2
  echo "  Refusing to create a duplicate fallback terminal on a guess." >&2
  echo "  Fix with: .orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree active" >&2
  exit 1
fi
if [[ "$FB_STATE" -eq 1 ]]; then
  echo "No fallback handle — creating role-agy-fallback…"
  WT="$(python3 - "$HANDLES_FILE" <<'PY' 2>/dev/null || echo active
import json
import sys

with open(sys.argv[1]) as stream:
    print(json.load(stream).get("worktree", "active"))
PY
)"
  WORKTREE="$WT"
  FB="$(create_role "$(role_meta fallback | cut -f1)" "$(role_launch_cmd fallback)")"
  handles_set "$HANDLES_FILE" fallback "$FB"
  echo "fallback handle: $FB"
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
echo "Wait+auto-close: .orca/orchestration/scripts/orca-wait-done.sh --role fallback --timeout-ms 900000"
