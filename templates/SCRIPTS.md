# Script reference

| Script | Purpose |
|--------|---------|
| `scripts/orca-bootstrap-roles.sh` | Start 4 role workers + write `handles.json` |
| `scripts/orca-dispatch-role.sh` | Supervised task + inject to a role |
| `scripts/orca-fallback-on-limit.sh` | Failover to agy Gemini 3.5 Flash (Medium) |

Personas: `.orca/orchestration/personas/<role>.md` are seeded by bootstrap and quoted
(one `STANCE` line) by dispatch. In the skill repo, `scripts/check-personas.sh` lints them.

```bash
chmod +x scripts/orca-*.sh
./scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
./scripts/orca-dispatch-role.sh architect --spec "Plan: …"
./scripts/orca-dispatch-role.sh thrifty --spec-file /tmp/task.md
./scripts/orca-dispatch-role.sh executor --deps '["task_xxx"]' --spec "Implement…"
./scripts/orca-fallback-on-limit.sh --from architect --spec "Continue…"
```

Roles: `architect` | `executor` | `thrifty` | `fallback`

Wait after dispatch:

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

`handles.json` is local-only; do not commit. See `handles.example.json`.
