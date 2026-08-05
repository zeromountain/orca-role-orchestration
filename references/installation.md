# Installation, layout, and update policy

Read when installing, updating, packaging, or debugging where a file came from.

## Layout (load-bearing — do not move `scripts/` or `templates/`)

```
orca-role-orchestration/
  SKILL.md                     # single skill at plugin root (Claude Code layout)
  .claude-plugin/
    plugin.json                # Claude plugin identity (no version: SHA channel)
    marketplace.json           # Claude self-marketplace catalog (source: "./")
  .codex-plugin/
    plugin.json                # Codex plugin identity (skills: "./", hooks: {})
  .agents/plugins/
    marketplace.json           # Codex marketplace catalog (source url "./")
  commands/                    # Claude Code slash commands (auto-discovered)
    install.md bootstrap.md dispatch.md wait.md fallback.md close.md status.md
  prompts/                     # Codex slash commands (symlinked into $CODEX_HOME/prompts)
    orca-install.md orca-bootstrap.md orca-dispatch.md orca-wait.md
    orca-fallback.md orca-close.md orca-status.md
  scripts/
    install-to-project.sh      # project scaffold install/update (idempotent)
    install-skill.sh           # global skill clone-or-pull + multi-agent symlinks
    orca-bootstrap-roles.sh    # start role workers (idempotent, resumable)
    orca-dispatch-role.sh      # supervised dispatch; recreates dead role tabs
    orca-status.sh             # doctor: preflight, liveness, unclosed dispatches
    orca-close-role.sh         # manual emergency close
    orca-reap-task.sh          # background auto-close on dispatch complete
    orca-wait-done.sh          # optional blocking wait
    orca-roles-lib.sh          # shared role meta / create / seed / state writes
    orca-fallback-on-limit.sh
    check-personas.sh          # lint persona skeleton + STANCE (dev/CI only)
  templates/                   # copied into project by install
    roles.yaml                 # managed routing (always refreshed)
    project_hints.yaml         # user-owned (create once)
    personas/                  # architect|executor|thrifty|fallback|coordinator .md
  tests/
    install.sh                 # installer regressions
    runtime.sh                 # runtime scripts against a fake `orca` on PATH
    repo-lint.sh               # manifests, command/prompt pairs, personas
    fake-orca/                 # PATH shim + stub role CLIs
  references/                  # this file and friends — read on demand
```

Conventional install root: `~/.agents/skills/orca-role-orchestration/`
(Grok may also see `~/.grok/skills/orca-role-orchestration` → symlink)

## Claude Code plugin marketplace

Self-marketplace; root `SKILL.md` is the single skill.

```text
/plugin marketplace add zeromountain/orca-role-orchestration
/plugin install orca-role-orchestration@orca-role-orchestration
```

Refresh after new commits (version is SHA-based — `plugin.json` has no `version`):

```text
/plugin marketplace update orca-role-orchestration
/plugin update orca-role-orchestration@orca-role-orchestration
```

Local dry-run from a checkout:

```bash
claude plugin validate .
claude --plugin-dir "$(pwd)"     # skill namespace: /orca-role-orchestration:…
```

## Codex plugin marketplace

```bash
codex plugin marketplace add zeromountain/orca-role-orchestration
codex plugin add orca-role-orchestration@orca-role-orchestration
codex plugin marketplace upgrade   # refresh snapshots
```

Codex plugin manifests carry no prompt field, so `install-skill.sh` symlinks
`prompts/*.md` into `$CODEX_HOME/prompts/`. Run it once after `codex plugin add`
to get the Codex slash commands.

## Global skill (multi-agent)

Same command installs and updates:

```bash
./scripts/install-skill.sh
# or: curl -fsSL …/install-skill.sh | bash
# remove: ./scripts/install-skill.sh --uninstall   # drops our symlinks, keeps the checkout
```

## Project scaffold

One flagless command for both first install and every update:

```bash
SKILL=~/.agents/skills/orca-role-orchestration
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)"
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)" --dry-run     # preview
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)" --reset       # recovery
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)" --uninstall
```

| Path | Policy on re-run |
|------|------------------|
| `roles.yaml`, `PLAYBOOK.md`, `SCRIPTS.md`, `scripts/*` | **Managed** — always refreshed to the skill template |
| `project_hints.yaml` | **Yours** — created once, never overwritten |
| `roles.local.json` | **Yours** — optional, never created or overwritten |
| `personas/*.md` | Refreshed only if unmodified since install (sha256 in `install-manifest.json`); forks preserved |
| `install-manifest.json` | Version stamp (`git describe --tags`) + file hashes |

Backups: a changed managed file is copied to `.bak` first, and an existing
`.bak` rotates to `.bak.1`, `.bak.2`, … so an older fork is never destroyed.

`--uninstall` removes managed scripts and docs, and removes personas only when
they still match the shipped template. It keeps `project_hints.yaml`,
`roles.local.json`, forked personas, and local runtime state, and prints what it
left behind.

Legacy single-file installs auto-migrate: `project` + `project_hints` are
extracted into `project_hints.yaml`, then managed `roles.yaml` is refreshed.

## Per-project model overrides

Optional user-owned `.orca/orchestration/roles.local.json` repoints a role
without forking any script — for a consumer who lacks one of the default CLIs:

```json
{
  "thrifty": {
    "model": "claude-sonnet-5",
    "launch_command": "claude --model claude-sonnet-5 --dangerously-skip-permissions"
  }
}
```

Recognised fields: `title`, `model`, `agent`, `launch_command`. The overridden
launch command's first word is what bootstrap's preflight checks on `PATH`.
Role **names** stay fixed at the four — they are wired into the routing table,
DAGs, personas, and every command file.

## Security

Default launch commands disable or bypass agent permission checks. Use them only
in trusted repositories, or remove the bypass flags before bootstrapping.

Local runtime state — `handles.json`, `dispatch-ledger.jsonl`, `*.lock`,
`reapers/` — is gitignored by the installer and must not be committed.
