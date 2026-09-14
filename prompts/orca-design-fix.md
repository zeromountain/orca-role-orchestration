---
description: Set up the Design Mode bug-fix loop: ui tab active, browser on the page
argument-hint: "<url> [--role ui] | --verify"
---

Arguments: `$ARGUMENTS` — the page URL, optionally `--role <role>` (default `ui`), or `--verify`.

The Orca recipe "Fix a UI bug with Design Mode". The click is UI-only; this command does the
setup around it so the attachment lands in the right agent.

```bash
.orca/orchestration/or fix http://localhost:3000/settings      # ui tab active + browser on the page
.orca/orchestration/or fix --verify                            # screenshot after the fix
```

1. It ensures the `ui` role tab exists (creating and seeding it if needed), makes it the active
   terminal — Design Mode attaches the clicked element to the *active* agent — and navigates the
   worktree browser to the URL. The dev server must already be running at that URL.
2. Then hand over: the user toggles Design Mode, clicks the broken element, and types the fix in
   the `ui` tab. Do not dispatch a separate task for the fix; the attachment *is* the task.
3. `--verify` captures a screenshot for the user to compare; repeat the click → describe loop until
   it looks right, then the user commits from Orca.
