# Script reference

| Script | Purpose |
|--------|---------|
| `.orca/orchestration/scripts/orca-bootstrap-roles.sh` | Start 4 role workers + write `handles.json` |
| `.orca/orchestration/scripts/orca-dispatch-role.sh` | Create a task + `worker-start` + **auto-reaper**; recreates dead tabs. `--after task_id[,…]` for a one-off dependency |
| `.orca/orchestration/scripts/orca-dispatch-dag.sh` | Wire a role DAG pattern (`plan-exec-review`\|`ui`\|`explore`) in one shot — creates every step with `--deps`, dispatches only the first (ready) step |
| `.orca/orchestration/scripts/orca-dispatch-existing.sh` | Attach a worker to an ALREADY-CREATED task — a later DAG wave, or `--retry-of <dispatch_id>` for same-role crash recovery (not cross-role failover — see `references/orca-contract-2026-08-13.md`) |
| `.orca/orchestration/scripts/orca-reap-task.sh` | Background: poll worker/dispatch status → `worker-release` (falls back to this package's own close when Orca reports the tab retained). Also detects a stalled worker (status stuck, screen unchanged, not busy) and reports it in the ledger — never closes on idle alone (Orca's contract forbids that) — `--idle-grace-ms`/`--idle-probe-ms`/`--idle-strikes` |
| `.orca/orchestration/scripts/orca-wait-done.sh` | Optional blocking wait (+ close if reaper/worker missed); acks every batch it fully processes. `--task ID` ignores any message for a different task instead of acting on it — pass it whenever you know the task id (`orca-dispatch-role.sh --wait` always does). Only one waiter at a time is supported: two concurrent `orca-wait-done.sh` processes race for the same `orca orchestration check` messages. |
| `.orca/orchestration/scripts/orca-close-role.sh` | Manual close of role tab (`--tab`) |
| `.orca/orchestration/scripts/orca-roles-lib.sh` | Shared role meta / dag patterns / dispatch primitives / seed (sourced) |
| `.orca/orchestration/scripts/orca-fallback-on-limit.sh` | Failover to agy Gemini 3.6 Flash (Medium) — new task, `[FAILOVER from …]` wrapper spec |
| `.orca/orchestration/scripts/orca-status.sh` | Doctor: preflight, role liveness, unclosed dispatches, reapers |
| `.orca/orchestration/scripts/orca-debate.sh` | Drive a 3-round four-model idea debate |
| `.orca/orchestration/scripts/orca-debate-round.sh` | One debate round: fan out, poll, collect, lint |
| `.orca/orchestration/scripts/orca-debate-lib.sh` | Debate helpers + round prompts (sourced) |
| `.orca/orchestration/scripts/orca-sweep-orphans.sh` | Report/close untracked role terminals; also the `--persist` dead-man watchdog |
| `.orca/orchestration/scripts/orca-race.sh` | Recipe: race N roles on one goal, one worktree each (`start`/`status`/`pick`/`finish`/`abort`/`list`); seats in `race-ledger.jsonl`, tabs retained until `pick` |
| `.orca/orchestration/scripts/orca-review.sh` | Recipe: open the diff viewer (`file open-changed` / `file diff`) and print the review keys; `--race <id> <seat>` |
| `.orca/orchestration/scripts/orca-worktrees.sh` | Recipe: `ps` (worktrees, agents, race seats, needs-input) / `gc [--close]` (merged worktrees; report-only by default, never `--force`) |
| `.orca/orchestration/scripts/orca-design-fix.sh` | Recipe: make the `ui` tab active + open the page in the worktree browser for Design Mode; `--verify` screenshots |
| `.orca/orchestration/or` | Short alias router: `or d/dag/x/w/s/f/sweep/debate/close/read/reply` + recipes `or race/review/ps/gc/fix/note/hosts` |

Personas: `.orca/orchestration/personas/<role>.md` are seeded by bootstrap and quoted
(one `STANCE` line) by dispatch. In the skill repo, `scripts/check-personas.sh` lints them.

```bash
chmod +x .orca/orchestration/scripts/orca-*.sh
.orca/orchestration/scripts/orca-status.sh                 # check before you start
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
.orca/orchestration/scripts/orca-bootstrap-roles.sh --roles architect,executor
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty --spec-file /tmp/task.md
.orca/orchestration/scripts/orca-dispatch-role.sh executor --after task_xxx --spec "Implement…"
.orca/orchestration/scripts/orca-dispatch-dag.sh plan-exec-review "OAuth login"   # wires 3 tasks, dispatches step 1
.orca/orchestration/scripts/orca-dispatch-existing.sh task_xxx executor          # dispatch a ready later step
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from architect --spec "Continue…"
.orca/orchestration/scripts/orca-debate.sh --topic "…"   # 3-round idea debate
.orca/orchestration/or race start "Fix the login bug"      # 3 seats (Opus/Sol/Grok), one worktree each
.orca/orchestration/or race pick <race_id> 2               # keep seat 2, delete the others' worktrees
.orca/orchestration/or review --race <race_id> 2           # open its diff; j/k/c + Send to agent in the UI
.orca/orchestration/or ps; .orca/orchestration/or gc       # worktree overview; merged-worktree report
.orca/orchestration/or fix http://localhost:3000/page      # Design Mode loop: ui tab active, page open
# close is automatic after dispatch; optional block — always pass --task (the
# task_id printed by dispatch): bare --role can act on a leftover worker_done
# message from an unrelated flow (e.g. a debate, which never drains its own
# inbox backlog) and close the wrong tab.
.orca/orchestration/scripts/orca-wait-done.sh --role thrifty --task task_xxx
.orca/orchestration/scripts/orca-close-role.sh thrifty   # manual emergency only
```

Roles: `architect` | `executor` | `thrifty` | `ui` | `reviewer` | `fallback` | `debater_*`

Release is **automatic** on every `orca-dispatch-role.sh` (background reaper calls
`worker-release`, falls back to its own close). Optional wait for the result body:

```bash
orca orchestration check --wait --types worker_done,escalation,decision_gate,question --timeout-ms 900000 --json
```

When a dispatch misbehaves, run `orca-status.sh` first. It is the only place
that surfaces `reap_failed` / `close_failed` / `release_unknown` rows (a worker
tab that stayed open after its reaper gave up) and `stalled` rows (the idle
probe found no progress — never closed on that alone, so it is always worth a
look). `awaiting_reply` rows are not a problem: the worker is correctly idle,
waiting on your reply to a `decision_gate`/`question` or `escalation`. Exit
code 1 means something needs attention.

`handles.json`, `dispatch-ledger.jsonl`, `race-ledger.jsonl`, and `reapers/` are
local-only; do not commit them. See `handles.example.json`.
