---
description: Install or update the Orca role-orchestration scaffold in this project (idempotent)
argument-hint: "[--project-name NAME] [--reset]"
---

Run the scaffold installer for the current project root:

```bash
SKILL="${CODEX_HOME:-$HOME/.codex}/skills/orca-role-orchestration"
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)" $ARGUMENTS
```

If that path is missing, fall back to `~/.agents/skills/orca-role-orchestration`.
Then report what was created/refreshed and tell the user to customize
`.orca/orchestration/project_hints.yaml` (never `roles.yaml`).
