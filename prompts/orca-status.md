---
description: Health check the Orca role scaffold — preflight, role liveness, unclosed dispatches, reapers
argument-hint: "[--quiet]"
---

Run the scaffold doctor:

```bash
.orca/orchestration/scripts/orca-status.sh $ARGUMENTS
```

Exit 0 means healthy; exit 1 means something needs attention. Report each section:

1. **preflight** — is Orca reachable, are `claude` / `codex` / `grok` / `agy` on PATH.
   A missing role CLI is the most common first-install failure; suggest
   `orca-bootstrap-roles.sh --roles <subset>` to skip that role.
2. **roles** — handle per role, live / closed / unknown. `closed` is normal
   (tabs are ephemeral; the next dispatch recreates them). `unknown` means Orca
   is unreachable, not that the tab is gone.
3. **dispatches not closed** — any `reap_failed` or `close_failed` row is a
   worker tab that may still be burning a session. Close it with
   `orca-close-role.sh <role|term_*>` and say so explicitly.
4. **reapers** — background watchers, running or stale.

Run this before diagnosing anything else about a misbehaving dispatch.
