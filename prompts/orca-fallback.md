---
description: Re-dispatch a rate/session-limited role to the Gemini Flash fallback worker
argument-hint: "<architect|executor|thrifty|term_*> <continuation goal>"
---

Arguments: `$ARGUMENTS` — first token is the limited role or handle, the rest is what remains to be done.

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role|handle> \
  --spec "Continue: <goal + partial progress>"
```

Do not retry the limited primary until its window resets. Fallback is not a quality lane.
