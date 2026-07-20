---
description: Emergency close of an Orca role worker terminal (normally automatic)
argument-hint: "<architect|executor|thrifty|fallback|term_*>"
---

```bash
.orca/orchestration/scripts/orca-close-role.sh $ARGUMENTS
```

Only for stuck tabs — dispatch already auto-closes workers. Safe to call twice;
the next dispatch recreates the handle.
