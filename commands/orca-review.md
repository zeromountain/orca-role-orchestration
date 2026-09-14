---
description: Open a worktree's AI diff in Orca's diff viewer and hand over the line-by-line review
argument-hint: "[<selector>] [--mode diff|both] [--path <file> [--staged]] [--race <id> <seat>]"
allowed-tools: Bash(.orca/orchestration/or:*), Bash(.orca/orchestration/scripts/orca-review.sh:*)
---

Arguments: `$ARGUMENTS` — an optional worktree selector and flags.

The Orca recipe "Review an AI diff line-by-line". Only its first step has a CLI; the rest is
the human in the diff viewer, so this command opens the view and hands over.

```bash
.orca/orchestration/or review                       # every changed file, diff mode, active worktree
.orca/orchestration/or review path:/abs/worktree --mode both
.orca/orchestration/or review --path src/app.ts --staged
.orca/orchestration/or review --race <race_id> <seat>
```

After it opens, tell the user the keys the script printed (`j`/`k` files, `c` comment,
**Send to agent** batches every comment into one prompt for that worktree's agent) and stop —
do not try to annotate or send notes from the CLI; there is no command for it. When the agent
has revised, the user reopens the diff; a dispatch you started can be watched with `or w`.
