# Script reference

| Script | Purpose |
|--------|---------|
| `.orca/orchestration/scripts/orca-bootstrap-roles.sh` | Start 4 role workers + write `handles.json` |
| `.orca/orchestration/scripts/orca-dispatch-role.sh` | Inject + **auto-reaper** (closes tab on complete); recreates dead tabs |
| `.orca/orchestration/scripts/orca-reap-task.sh` | Background: poll dispatch status → `terminal close --tab` |
| `.orca/orchestration/scripts/orca-wait-done.sh` | Optional blocking wait (+ close if reaper/worker missed) |
| `.orca/orchestration/scripts/orca-close-role.sh` | Manual close of role tab (`--tab`) |
| `.orca/orchestration/scripts/orca-roles-lib.sh` | Shared role meta / create / seed (sourced) |
| `.orca/orchestration/scripts/orca-fallback-on-limit.sh` | Failover to agy Gemini 3.5 Flash (Medium) |

Personas: `.orca/orchestration/personas/<role>.md` are seeded by bootstrap and quoted
(one `STANCE` line) by dispatch. In the skill repo, `scripts/check-personas.sh` lints them.

```bash
chmod +x .orca/orchestration/scripts/orca-*.sh
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty --spec-file /tmp/task.md
.orca/orchestration/scripts/orca-dispatch-role.sh executor --deps '["task_xxx"]' --spec "Implement…"
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from architect --spec "Continue…"
# close is automatic after dispatch; optional block:
.orca/orchestration/scripts/orca-wait-done.sh --role thrifty
.orca/orchestration/scripts/orca-close-role.sh thrifty   # manual emergency only
```

Roles: `architect` | `executor` | `thrifty` | `fallback`

Close is **automatic** on every `orca-dispatch-role.sh` (background reaper). Optional wait for the result body:

```bash
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 900000 --json
```

`handles.json` is local-only; do not commit. See `handles.example.json`.
