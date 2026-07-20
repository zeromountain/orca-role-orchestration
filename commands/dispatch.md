---
description: Dispatch a task to an Orca role worker (supervised, auto-closing tab)
argument-hint: "<architect|executor|thrifty|fallback> <task description>"
allowed-tools: Bash(.orca/orchestration/scripts/orca-dispatch-role.sh:*), Read
---

Arguments: `$ARGUMENTS` — first token is the role, the rest is the task intent.

1. If no role token is given, pick one from `.orca/orchestration/roles.yaml` routing_table
   plus `.orca/orchestration/project_hints.yaml`. Image generation intent → `executor`
   (apply the SKILL.md clarity gate before dispatching).
2. Expand the intent into a proper spec: goal, constraints, allowed file scope, done definition.
3. Dispatch:

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh <role> --spec "<expanded spec>"
```

The tab auto-closes via the background reaper — do not close it manually.
Report the task id and dispatch handle.
