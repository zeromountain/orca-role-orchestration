---
description: Bootstrap Orca role workers (architect / executor / thrifty / fallback)
argument-hint: "[--worktree path:PATH]"
allowed-tools: Bash(.orca/orchestration/scripts/orca-bootstrap-roles.sh:*), Bash(orca status:*)
---

1. Check runtime: `orca status --json` (runtime.reachable must be true).
2. Bootstrap:

```bash
.orca/orchestration/scripts/orca-bootstrap-roles.sh ${ARGUMENTS:---worktree path:$(pwd)}
```

If `.orca/orchestration/scripts/` is missing, tell the user to run `/orca-role-orchestration:install` first.
Report the handles written to `.orca/orchestration/handles.json`.
