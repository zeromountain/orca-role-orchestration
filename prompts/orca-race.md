---
description: Race several Orca role workers on one goal, one worktree each, then pick the winner
argument-hint: "start \"<goal>\" [--roles a,b,c] | status <id> | pick <id> <seat> | finish <id> | abort <id>"
---

Arguments: `$ARGUMENTS` — a subcommand (`start|status|pick|finish|abort|list`) and its arguments.

The Orca recipe "Race three agents on the same task", run from the coordinator: each role
gets its own worktree from the same base branch, its own tab, and a supervised dispatch of the
same goal. Tabs stay open until you pick, so the diff viewer's **Send to agent** has a live
target.

```bash
.orca/orchestration/or race start "<goal>" [--roles architect,executor,thrifty] [--base-branch main] [--reap]
.orca/orchestration/or race status <race_id>
.orca/orchestration/or race pick <race_id> <seat>      # removes the other seats' worktrees (--force)
.orca/orchestration/or race finish <race_id>           # releases the winner's tab, keeps its worktree
.orca/orchestration/or race abort <race_id>            # removes every non-winner seat
```

1. `start` needs a bound Run (same rule as dispatch) and at least two roles. Expand a terse
   goal into a real spec first (goal, constraints, done definition) — every seat gets the
   same text, so vagueness is multiplied. Exit 2 means fewer than two seats started; run
   `abort` to clean up. Report the `race_id` and each seat's task id.
2. While seats run, `status` shows worker state and per-worktree change counts. The
   comparison itself — reading each seat's diff — is done by the human in Orca's diff
   viewer (`or review --race <race_id> <seat>` opens one); agreement across seats is a
   confidence signal, disagreement marks the genuinely hard part.
3. `pick` is destructive for the losers (worktree, tab and branch are deleted) — confirm the
   seat number with the user before running it. It opens the winner's diff and marks the
   worktree in-review; commit/push/PR happen in Orca's UI.
4. Any `start_failed` / `rm_failed` seat shows in `or s` section [5]; retry with `pick` or
   `abort`. Never delete race worktrees by hand — the ledger is what makes cleanup safe.
