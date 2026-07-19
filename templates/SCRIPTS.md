# Script reference

| Script | Purpose |
|--------|---------|
| `.orca/orchestration/scripts/orca-bootstrap-roles.sh` | Start 4 role workers + write `handles.json` |
| `.orca/orchestration/scripts/orca-dispatch-role.sh` | Supervised task + inject; recreates dead role tabs; `--wait` auto-closes |
| `.orca/orchestration/scripts/orca-wait-done.sh` | **Preferred wait** — `check --wait` + auto-close worker tab on `worker_done` |
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
.orca/orchestration/scripts/orca-wait-done.sh --role thrifty
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty --spec "…" --wait
.orca/orchestration/scripts/orca-close-role.sh thrifty   # manual fallback
```

Roles: `architect` | `executor` | `thrifty` | `fallback`

Wait after dispatch (**use wait-done — auto-closes**):

```bash
.orca/orchestration/scripts/orca-wait-done.sh --role <role> --timeout-ms 900000
```

`handles.json` is local-only; do not commit. See `handles.example.json`.
