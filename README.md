# Orca Role Orchestration

An installable Agent Skill and project scaffold for routing Orca Agent IDE work across four model-specific roles.

| Role | Default model | Best for |
|---|---|---|
| `architect` | Claude Opus 4.8 | Architecture, planning, high-risk review |
| `executor` | GPT-5.6 Sol via Codex | Implementation, debugging, verification, raster images via `$imagegen` |
| `thrifty` | Grok 4.5 | Exploration, research, small low-risk changes |
| `fallback` | Gemini 3.5 Flash (Medium) via `agy` | Continuity after rate or session limits |

The defaults are intentionally opinionated. Launch commands live in `scripts/orca-bootstrap-roles.sh` (not `roles.yaml`). Edit that script if you need different model IDs or CLI flags.

## Prerequisites

- Orca Agent IDE with **Settings → Experimental → Agent orchestration** enabled
- `orca`, `claude`, `codex`, `grok`, and `agy` available on `PATH`
- Python 3 and Bash

Check the local runtime before bootstrapping:

```bash
.orca/orchestration/scripts/orca-status.sh   # after install; exit 1 = something to fix
```

Don't have all four CLIs? Point a role at a model you do have — see
[per-project overrides](#per-project-model-overrides).

## Install for Claude Code (plugin marketplace)

This repo is a **self-contained marketplace** (same pattern as Superpowers): root `SKILL.md` + `.claude-plugin/` manifests. Layout stays at repo root so `scripts/install-to-project.sh` paths keep working.

```text
/plugin marketplace add zeromountain/orca-role-orchestration
/plugin install orca-role-orchestration@orca-role-orchestration
```

CLI:

```bash
claude plugin marketplace add zeromountain/orca-role-orchestration
claude plugin install orca-role-orchestration@orca-role-orchestration
```

Local dry-run from a checkout:

```bash
claude plugin validate .
claude --plugin-dir "$(pwd)"
# skill namespace: /orca-role-orchestration:…
```

Refresh after new commits (plugin version is SHA-based — no pin field in `plugin.json`):

```text
/plugin marketplace update orca-role-orchestration
/plugin update orca-role-orchestration@orca-role-orchestration
```

Claude plugin install loads the skill for Claude Code. For **project scaffold** and multi-agent paths (`~/.agents/skills`, Codex/Grok), also use `install-skill.sh` below (or run `install-to-project.sh` from the plugin cache / a clone).

## Install for Codex (plugin marketplace)

Codex discovers this repo via `.agents/plugins/marketplace.json` and loads the plugin from `.codex-plugin/plugin.json` (root single skill, `skills: "./"`, empty `hooks: {}` so no Claude hooks leak in).

```bash
codex plugin marketplace add zeromountain/orca-role-orchestration
codex plugin add orca-role-orchestration@orca-role-orchestration
```

Local dry-run from a checkout:

```bash
codex plugin marketplace add "$(pwd)"
codex plugin add orca-role-orchestration@orca-role-orchestration
codex plugin list
```

Refresh marketplace snapshots after new commits:

```bash
codex plugin marketplace upgrade
```

Same note as Claude: plugin install loads the skill into Codex; project scaffold still uses `install-to-project.sh` from a full skill root (`install-skill.sh`, clone, or plugin cache).

## Install or update the global skill (multi-agent)

Same command installs and updates (clone-or-pull + optional multi-agent symlinks):

```bash
# from a checkout, or curl raw from GitHub
curl -fsSL https://raw.githubusercontent.com/zeromountain/orca-role-orchestration/main/scripts/install-skill.sh | bash
# or:
./scripts/install-skill.sh
```

Canonical path: `~/.agents/skills/orca-role-orchestration`. If `~/.claude/skills`, `~/.codex/skills`, or `~/.grok/skills` exist, they get a symlink to that checkout.

Restart or reload your agent so it discovers `SKILL.md`.

## Install or update the project scaffold

**One flagless command** — safe to re-run anytime:

```bash
~/.agents/skills/orca-role-orchestration/scripts/install-to-project.sh \
  --project-root "$(pwd)"
```

| Layer | Path | On re-run |
|-------|------|-----------|
| Managed routing | `.orca/orchestration/roles.yaml` | Always refreshed (`.bak` if changed) |
| Your hints | `.orca/orchestration/project_hints.yaml` | Created once; **never** overwritten |
| Personas | `.orca/orchestration/personas/*.md` | Refresh if unmodified; skip if forked |
| Scripts / docs | `scripts/`, `PLAYBOOK.md`, … | Always refreshed |
| Your overrides | `.orca/orchestration/roles.local.json` | Created by you; **never** touched |
| Version stamp | `install-manifest.json` | Written every run |

A changed managed file is backed up to `.bak`, and an existing `.bak` rotates to
`.bak.1`, `.bak.2`, … so an older fork is never destroyed.

```bash
…/install-to-project.sh --project-root "$(pwd)" --dry-run     # preview, writes nothing
…/install-to-project.sh --project-root "$(pwd)" --reset       # overwrite forked personas
…/install-to-project.sh --project-root "$(pwd)" --uninstall   # keeps your files
```

## Per-project model overrides

Optional `.orca/orchestration/roles.local.json` repoints a role without forking a
script — for when you don't have one of the default CLIs:

```json
{
  "thrifty": {
    "model": "claude-sonnet-5",
    "launch_command": "claude --model claude-sonnet-5 --dangerously-skip-permissions"
  }
}
```

Fields: `title`, `model`, `agent`, `launch_command`. Role **names** stay fixed at
the four — they are wired into routing, DAGs, personas and every command file.
Bootstrap can also run a subset: `--roles architect,executor`.

Then bootstrap workers (idempotent — re-run to finish a partial bootstrap):

```bash
orca repo add --path "$(pwd)" # only if the project is not already in Orca
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree "path:$(pwd)"
```

See [`SKILL.md`](./SKILL.md) for routing behavior and [`templates/PLAYBOOK.md`](./templates/PLAYBOOK.md)
for the supervised lifecycle. Detail lives in [`references/`](./references):
[installation](./references/installation.md) · [routing](./references/routing.md) ·
[image generation](./references/image-generation.md) · [model roles](./references/model-roles.md).

## Development

```bash
tests/repo-lint.sh    # plugin manifests, Claude/Codex command pairs, personas
tests/install.sh      # installer regressions (managed / user-owned / fork policy)
tests/runtime.sh      # runtime scripts against a fake `orca` — no Orca needed
shellcheck scripts/*.sh tests/*.sh tests/fake-orca/orca
```

`tests/runtime.sh` puts `tests/fake-orca/` first on `PATH` and installs the
scaffold into a tmp project, so each case also proves that what the installer
emits is runnable. `tests/fake-orca/orca` supports failure injection via
`$FAKE_ORCA_STATE/fail/<subcommand>` — that is what covers the close/reap
failure paths. CI runs all three suites plus shellcheck on macOS and Ubuntu.

Changes to managed files are recorded in [`CHANGELOG.md`](./CHANGELOG.md).

## Security

The default launch commands disable or bypass agent permission checks. Use them only in trusted repositories and review the commands before running `orca-bootstrap-roles.sh`. Remove the bypass flags if you want each provider's normal approval boundaries.

Generated `.orca/orchestration/handles.json` files are local runtime state and must not be committed.

## License

MIT — see [`LICENSE`](./LICENSE).
