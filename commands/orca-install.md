---
description: Install or update the Orca role-orchestration scaffold in this project (idempotent)
argument-hint: "[--project-name NAME] [--reset]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/install-to-project.sh:*)
---

Run the scaffold installer for the current project root:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/install-to-project.sh" --project-root "$(pwd)" $ARGUMENTS
```

Then report what was created/refreshed and tell the user to customize
`.orca/orchestration/project_hints.yaml` (never `roles.yaml`).
