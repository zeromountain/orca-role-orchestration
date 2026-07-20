---
description: Wait for worker_done / escalation / decision_gate from Orca role workers
argument-hint: "[--timeout-ms N] [--role ROLE]"
---

```bash
.orca/orchestration/scripts/orca-wait-done.sh $ARGUMENTS
```

Timeout or `count:0` is a checkpoint, not a failure — report it as such.
Synthesize any `worker_done` bodies into a short summary for the user.
