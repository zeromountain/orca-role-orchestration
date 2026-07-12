# Orca Role Orchestration

An installable Agent Skill and project scaffold for routing Orca Agent IDE work across four model-specific roles.

| Role | Default model | Best for |
|---|---|---|
| `architect` | Claude Opus 4.8 | Architecture, planning, high-risk review |
| `executor` | GPT-5.6 Sol via Codex | Implementation, debugging, verification |
| `thrifty` | Grok 4.5 | Exploration, research, small low-risk changes |
| `fallback` | Gemini 3.5 Flash (Medium) via `agy` | Continuity after rate or session limits |

The defaults are intentionally opinionated. Model IDs and CLI flags can change; edit the launch commands in `templates/roles.yaml` and the bootstrap script to match your installed providers.

## Prerequisites

- Orca Agent IDE with **Settings → Experimental → Agent orchestration** enabled
- `orca`, `claude`, `codex`, `grok`, and `agy` available on `PATH`
- Python 3 and Bash

Check the local runtime before bootstrapping:

```bash
orca status --json
which orca claude codex grok agy
```

## Install as a global Agent Skill

```bash
mkdir -p ~/.agents/skills
git clone https://github.com/zeromountain/orca-role-orchestration.git \
  ~/.agents/skills/orca-role-orchestration
```

Restart or reload your agent so it discovers `SKILL.md`. You can then ask it to use `orca-role-orchestration` or run the scaffold installer directly.

## Add the scaffold to a project

From the target project:

```bash
~/.agents/skills/orca-role-orchestration/scripts/install-to-project.sh \
  --project-root "$(pwd)"
```

This adds:

- `.orca/orchestration/roles.yaml` as the routing source of truth
- `.orca/orchestration/personas/<role>.md` — per-role personas seeded into workers
- `.orca/orchestration/PLAYBOOK.md` and script documentation
- bootstrap, dispatch, and rate-limit fallback scripts under `.orca/orchestration/scripts/`
- a gitignore entry for local Orca terminal handles

Then customize `.orca/orchestration/roles.yaml` and bootstrap the workers:

```bash
orca repo add --path "$(pwd)" # only if the project is not already in Orca
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree "path:$(pwd)"
```

See [`SKILL.md`](./SKILL.md) for routing behavior and [`templates/PLAYBOOK.md`](./templates/PLAYBOOK.md) for the supervised lifecycle.

## Update an existing install

If you scaffolded a project before the persona system existed, upgrade it in place:

```bash
~/.agents/skills/orca-role-orchestration/scripts/install-to-project.sh \
  --project-root "$(pwd)" --update
```

`--update` adds `.orca/orchestration/personas/`, refreshes the bootstrap/dispatch/fallback scripts and
playbook docs (backing up any changed file to `<file>.bak`), and **preserves your `roles.yaml`**
(`project_hints`, launch commands) and `handles.json`. If you customized launch commands inside the
scripts, re-apply them from the `.bak` copies.

Add `--migrate-roles` to also rewrite the legacy inline `persona:` blocks in `roles.yaml` to
`persona_file:` references (original saved as `roles.yaml.bak`). This is optional — the scripts read the
persona files directly, so persona injection works with or without the migration.

## Security

The default launch commands disable or bypass agent permission checks. Use them only in trusted repositories and review the commands before running `orca-bootstrap-roles.sh`. Remove the bypass flags if you want each provider's normal approval boundaries.

Generated `.orca/orchestration/handles.json` files are local runtime state and must not be committed.

## License

MIT — see [`LICENSE`](./LICENSE).
