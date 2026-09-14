---
description: List Orca worktrees with agent state, or garbage-collect merged ones
argument-hint: "ps | gc [--base <ref>] [--close]"
---

Arguments: `$ARGUMENTS` — `ps`, or `gc [--base <ref>] [--close]`.

The CLI half of the Orca recipe "Jump between 10 worktrees":

```bash
.orca/orchestration/or ps                 # every worktree: live terminals, agents, notes, race seats, who needs input
.orca/orchestration/or gc                 # worktrees whose branch is merged into the main worktree's branch (report only)
.orca/orchestration/or gc --close         # remove them (orca worktree rm, never --force)
.orca/orchestration/or note "reproduced; testing fix" --workspace-status in-progress   # worktree checkpoint (comment + board status)
```

- `ps` is the coordinator's jump palette: "needs-input" next to a seat is the yellow dot.
  The palette itself (Cmd-J), the Restart chip and the notification bell are UI-only; the
  Restart equivalent from here is `orca terminal create --worktree <sel> --command <launch>`.
- `gc` follows the recipe's advice to delete merged worktrees aggressively, but it is
  report-only until `--close`, and even then skips the main worktree, the current directory's
  worktree and anything with live terminals. Show the report and get a yes before `--close`.
- Use `note` liberally: comments show in the palette and sidebar, so a one-line checkpoint
  per milestone is what makes ten worktrees navigable.
