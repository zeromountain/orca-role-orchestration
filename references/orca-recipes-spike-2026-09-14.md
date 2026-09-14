# Orca recipes spike — 2026-09-14

Live probe of the `orca` CLI (v1.4.202, macOS, local host only) that decides how
`orca-race.sh` / `orca-worktrees.sh` / `orca-review.sh` talk to worktrees. Same
format as `orca-contract-2026-08-13.md`: question → answer → raw evidence. The
fake `orca` in `tests/fake-orca/` mimics the shapes recorded here.

## S1 — what does `worktree create --json` return? `result.worktree.{id,path,branch,baseRef}`.

```
orca worktree create --name race-spike-1 --base-branch main --json
result.worktree.id      = "<repoId>::/Users/…/orca/workspaces/orca-role-orchestration/race-spike-1"
result.worktree.path    = "/Users/…/orca/workspaces/orca-role-orchestration/race-spike-1"
result.worktree.branch  = "refs/heads/zeromountain/race-spike-1"
result.worktree.baseRef = "main"
result.worktree.isMainWorktree = false
result.worktree.parentWorktreeId = "<repoId>::<caller worktree path>"   # inferred parent
result.lineage / result.workspaceLineage / result.warnings []
```

No `startupTerminal` key on this version, but the worktree *does* get an inert
"Terminal 1" shell tab (`terminal list --worktree path:<new>` shows one handle,
title null). We leave it alone: `worktree rm` removes it with the worktree.
Selector of choice is `path:<abs path>` — ids contain `::` and a path.

## S2 — can we `terminal create --worktree path:<new>` right away? YES.

Immediately after S1, `orca terminal create --worktree "path:$WT" --title
race-spike-architect --command 'claude …' --json` returned
`result.terminal.{handle,tabId,worktreeId,title,surface:"visible"}` — the same
shape `create_role()` already parses. No readiness wait needed for the create.

## S3 — does `worker-start --task --terminal <h> --worktree path:<new>` work? YES.

```
result.dispatchId = "ctx_…"     # same field dispatch_task_to_role reads
result.state = "ready", stage = "input_accepted"
result.effects[] = worktree reused / terminal reused / dispatch_input accepted
result.residualResources = []
```

Caveat reproduced live: `worker-start` injects the spec the moment the terminal
is `tui-idle`, and Claude's bypass-permissions dialog *is* tui-idle — the injected
text selected "No, exit". That is exactly what `terminal_wait_ready()` + `seed()`
exist for; the race script must go through them (as `dispatch_task_to_role` does)
and never call `worker-start` on a tab that has not passed the readiness gate.

## S4 — cleanup ordering. `worker-release` refuses an unsettled worker; `worktree rm --force` closes live tabs.

```
worker-release --dispatch ctx_… (worker still "ready")
  → ok:false error.code = "dispatch_inactive"
    "only a settled worker can release. Use worker-stop to cancel an active worker."
worktree rm --worktree path:$WT --force --json   (2 live terminals in the worktree)
  → ok:true result.removed = true; both tabs gone, checkout dir gone, branch deleted
worker-show afterwards → worker.state = "failed", observation.status = "exited"
worker-stop afterwards → {state:"failed", alreadySettled:true, processAction:"none"}   exit 0
worker-release afterwards → {state:"retained", reason:"external_terminal"}             exit 0
```

Net rule for a losing seat: `worker-stop` (idempotent) → `worker-release`
(retained is fine, it is our external terminal) → `worktree rm --force`, then
verify with `worktree show` (error = gone). No separate `terminal close` needed:
the rm closes the tabs. `worker-stop` "never deletes the worktree".

## S6 — `worktree ps --json` and `worker-show` fields for `or ps`.

`result.worktrees[]` rows: `worktreeId, path, branch, displayName, comment,
workspaceStatus, isMainWorktree, isActive, liveTerminalCount, status
("active"|…), agents[] {state ("done"|…), agentType, prompt, taskTitle,
lastAssistantMessage}` plus `result.hostScope / totalCount / truncated`.
`worker-show` → `result.observation = {status:"live"|"exited", exactWorker,
agentWait:null|{…}}` — `agentWait` non-null is the "needs input" yellow dot.

## Not verified here

- Remote seats (`worktree create --project <id> --host ssh:<id>`): this machine's
  `host list` has only `local`. `or race start --host` passes the flags through
  untested.
- `worktree rm` **without** `--force` on a merged branch (used by `or gc`): the
  help text says Orca keeps branches it cannot prove merged; not exercised.
