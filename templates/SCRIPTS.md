# Script reference

| Script | Purpose |
|--------|---------|
| `.orca/orchestration/scripts/orca-bootstrap-roles.sh` | Start 4 role workers + write `handles.json` |
| `.orca/orchestration/scripts/orca-dispatch-role.sh` | Inject + **auto-reaper** (closes tab on complete); recreates dead tabs |
| `.orca/orchestration/scripts/orca-reap-task.sh` | Background: poll dispatch status → `terminal close --tab` |
| `.orca/orchestration/scripts/orca-wait-done.sh` | Optional blocking wait (+ close if reaper/worker missed); `--task ID` ignores any message for a different task instead of acting on it — pass it whenever you know the task id (`orca-dispatch-role.sh --wait` always does). Only one waiter at a time is supported: two concurrent `orca-wait-done.sh` processes race for the same `orca orchestration check` messages. |
| `.orca/orchestration/scripts/orca-close-role.sh` | Manual close of role tab (`--tab`) |
| `.orca/orchestration/scripts/orca-roles-lib.sh` | Shared role meta / create / seed (sourced) |
| `.orca/orchestration/scripts/orca-fallback-on-limit.sh` | Failover to agy Gemini 3.6 Flash (Medium) |
| `.orca/orchestration/scripts/orca-status.sh` | Doctor: preflight, role liveness, unclosed dispatches, reapers |
| `.orca/orchestration/scripts/orca-debate.sh` | Drive a 3-round four-model idea debate |
| `.orca/orchestration/scripts/orca-debate-round.sh` | One debate round: fan out, poll, collect, lint |
| `.orca/orchestration/scripts/orca-debate-lib.sh` | Debate helpers + round prompts (sourced) |
| `.orca/orchestration/scripts/orca-sweep-orphans.sh` | Report/close untracked role terminals; also the `--persist` dead-man watchdog |

Personas: `.orca/orchestration/personas/<role>.md` are seeded by bootstrap and quoted
(one `STANCE` line) by dispatch. In the skill repo, `scripts/check-personas.sh` lints them.

```bash
chmod +x .orca/orchestration/scripts/orca-*.sh
.orca/orchestration/scripts/orca-status.sh                 # check before you start
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
.orca/orchestration/scripts/orca-bootstrap-roles.sh --roles architect,executor
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty --spec-file /tmp/task.md
.orca/orchestration/scripts/orca-dispatch-role.sh executor --deps '["task_xxx"]' --spec "Implement…"
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from architect --spec "Continue…"
.orca/orchestration/scripts/orca-debate.sh --topic "…"   # 3-round idea debate
# close is automatic after dispatch; optional block — always pass --task (the
# task_id printed by dispatch): bare --role can act on a leftover worker_done
# message from an unrelated flow (e.g. a debate, which never drains its own
# inbox backlog) and close the wrong tab.
.orca/orchestration/scripts/orca-wait-done.sh --role thrifty --task task_xxx
.orca/orchestration/scripts/orca-close-role.sh thrifty   # manual emergency only
```

Roles: `architect` | `executor` | `thrifty` | `ui` | `reviewer` | `fallback` | `debater_*`

Close is **automatic** on every `orca-dispatch-role.sh` (background reaper). Optional wait for the result body:

```bash
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 900000 --json
```

When a dispatch misbehaves, run `orca-status.sh` first. It is the only place
that surfaces `reap_failed` / `close_failed` rows — a worker tab that stayed
open after its reaper gave up. Exit code 1 means something needs attention.

`handles.json`, `dispatch-ledger.jsonl`, and `reapers/` are local-only; do not
commit them. See `handles.example.json`.
