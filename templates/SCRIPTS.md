# Script reference

| Script | Purpose |
|--------|---------|
| `.orca/orchestration/scripts/orca-bootstrap-roles.sh` | Start 4 role workers + write `handles.json` |
| `.orca/orchestration/scripts/orca-dispatch-role.sh` | Supervised task + inject; recreates dead role tabs |
| `.orca/orchestration/scripts/orca-close-role.sh` | Close role tab after `worker_done` (ephemeral) |
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
.orca/orchestration/scripts/orca-close-role.sh thrifty   # after that role's worker_done
```

Roles: `architect` | `executor` | `thrifty` | `fallback`

Wait after dispatch:

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
# then close the completing role tab
.orca/orchestration/scripts/orca-close-role.sh <role>
```

`handles.json` is local-only; do not commit. See `handles.example.json`.
