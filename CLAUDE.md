# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An **Agent Skill package** (not an application): `SKILL.md` at root plus Bash/Python-3 scaffold templates that get installed into *other* projects. There is no build step and no runtime dependencies beyond `bash`, `python3`, and the `orca` CLI.

The repo simultaneously acts as its own plugin marketplace for two hosts:

| Host | Marketplace manifest | Plugin manifest | Discovery |
|---|---|---|---|
| Claude Code | `.claude-plugin/marketplace.json` (`source: "./"`) | `.claude-plugin/plugin.json` | root `SKILL.md`, `commands/*.md` auto-discovered |
| Codex | `.agents/plugins/marketplace.json` | `.codex-plugin/plugin.json` (`skills: "./"`, `hooks: {}`) | root `SKILL.md`; `prompts/*.md` need `install-skill.sh` symlinks into `$CODEX_HOME/prompts/` |

**Root layout is load-bearing.** `scripts/install-to-project.sh` computes `SKILL_DIR="$(dirname $0)/.."` and reads `$SKILL_DIR/templates` + `$SKILL_DIR/scripts`. Moving `scripts/` or `templates/` breaks every installer path. `.codex-plugin/plugin.json` must keep `hooks: {}` so Claude hooks don't leak into Codex.

## Commands

```bash
tests/repo-lint.sh            # plugin manifests, Claude/Codex command pairs, personas
tests/install.sh              # installer regressions T1–T11
tests/runtime.sh              # runtime scripts R1–R8 against a fake `orca` on PATH
scripts/check-personas.sh     # persona lint alone (dev/CI; not installed into projects)
shellcheck scripts/*.sh tests/*.sh tests/fake-orca/orca
```

No single-test runner. To isolate a case, comment out the other `# --- Tn` / `# --- Rn`
blocks, or read the per-case logs each run writes (`/tmp/install-t<N>.out`, and
`$tmproot` echoed in runtime.sh's first line).

`tests/runtime.sh` needs no Orca: it puts `tests/fake-orca/` first on `PATH` (a shim,
not a shell function — `orca-dispatch-role.sh` `nohup`s the reaper as a separate
process). Each case installs the scaffold into a tmp project and runs scripts from
there, so every runtime test also asserts the installer's output is runnable.
Failure paths are reachable via `$FAKE_ORCA_STATE/fail/<subcommand>`: create the file
to make that subcommand exit 1, or put `garbage` in it to emit non-JSON.

Local plugin dry-run:

```bash
claude plugin validate .
claude --plugin-dir "$(pwd)"       # skill namespace: /orca-role-orchestration:…
codex plugin marketplace add "$(pwd)" && codex plugin add orca-role-orchestration@orca-role-orchestration
```

## Two lives of `scripts/`

Every `scripts/orca-*.sh` file exists in two places and only works correctly in the second:

- **Source of truth**: `scripts/` in this repo — what you edit.
- **Installed copy**: `<project>/.orca/orchestration/scripts/` — where it runs.

The runtime scripts resolve their own paths as `ORCH="$HERE/.."` and `ROOT="$ORCH/../.."`, which is only correct under `.orca/orchestration/scripts/`. To exercise a script change, re-run the installer (this repo self-installs into its own gitignored `.orca/`), then run from the installed path:

```bash
scripts/install-to-project.sh --project-root "$(pwd)"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty --spec "…"
```

`install-to-project.sh` deliberately skips relocating `scripts/` when `ROOT == SKILL_DIR`, so self-installing does not eat the package's own sources.

`scripts/install-skill.sh` and `scripts/check-personas.sh` are the exceptions — they stay in the skill root and are never copied into projects (see the copy list in `install-to-project.sh`, which appears **twice**: the copy loop and the legacy-relocation loop).

## Where role facts actually live

Launch commands are **not** in `roles.yaml`. In executable code the binding exists in
exactly one place — keep it that way:

1. `scripts/orca-roles-lib.sh` → `role_meta()` (title/model/agent) and `role_launch_cmd()`.
   `handles_set()` and bootstrap both consume `role_meta`; they used to restate it and
   had already drifted.
2. `templates/roles.yaml`, `SKILL.md`, `README.md`, and the AGENTS.md snippet in
   `install-to-project.sh` restate it as **prose** — update for accuracy, but nothing
   parses them.

Consumers override per project via `.orca/orchestration/roles.local.json`
(`role_overrides()`), which `role_meta` / `role_launch_cmd` / `role_cli` all consult.
That file uses `\x1f` as its field separator, not tab: tab is an IFS *whitespace*
character, so bash `read` collapses runs of it and drops leading ones — which silently
shifts every empty field.

`LIMIT_RE` in `scripts/orca-fallback-on-limit.sh` is the only copy of the limit-detection
patterns; the stale mirror in `roles.yaml` was deleted rather than re-synced (syncing
would need a YAML parser this package deliberately does not have).

## Persona contract

`templates/personas/<role>.md` is the single source for worker seeding. Two consumers read the same file differently:

- `orca-roles-lib.sh:persona_body()` — strips the `# ` H1 and the `<!-- STANCE: … -->` comment, sends the rest as the bootstrap seed. Missing file → hardcoded one-liner from `role_fallback_body()`.
- `orca-dispatch-role.sh` — greps only the `STANCE:` line and prepends it to each task spec. Missing file → no stance line.

`check-personas.sh` enforces the H1, a non-empty STANCE, and nine literal `**Section.**` headings across all five roles (including `coordinator`, which has no worker terminal). Adding a section to one persona means adding it to all five plus the `SECTIONS` array.

## Installer file policy (what `tests/install.sh` protects)

`install-to-project.sh` is idempotent by design and classifies every destination file:

| Class | Files | Behavior on re-run |
|---|---|---|
| Managed | `roles.yaml`, `PLAYBOOK.md`, `SCRIPTS.md`, `handles.example.json`, `scripts/orca-*.sh` | Always overwritten; backed up only when content differs |
| User-owned | `project_hints.yaml`, `roles.local.json` | Created once (or by the user); never touched again, including under `--reset` |
| Fork-preserving | `personas/*.md` | Refreshed only if the current sha256 matches the hash recorded in `install-manifest.json`; otherwise preserved. No prior hash → treated as forked (fail-safe) |

`install-manifest.json` is both the version stamp (`git describe --tags`) and the hash ledger that makes fork detection work — never stop writing it. `--reset` is the only escape hatch for forked personas. Removed flags (`--force`, `--update`, `--fresh`, `--migrate-roles`) exit 1 with a pointer to the flagless form; keep that behavior.

`backup_file()` rotates: an existing `.bak` moves to `.bak.1`, `.bak.2`, … before the new one is written, so a fork that survives one upgrade is not lost on the next. `--dry-run` must keep every write behind its guard (it also skips `mkdir`); `--uninstall` removes personas only when they still match the shipped template.

A one-time migration extracts `project:` and `project_hints:` out of a legacy single-file `roles.yaml` into `project_hints.yaml` before the managed refresh (covered by T7).

Regression coverage worth preserving: T2 (re-run produces zero `.bak`), T3 (hints survive), T5 (forked persona survives), T7 (legacy migration), T9 (dry-run writes nothing), T10 (backup rotation), T11 (uninstall keeps user files).

## Supervised dispatch lifecycle

`orca-dispatch-role.sh` is the entry point for all supervised work; `orca-bootstrap-roles.sh` only pre-warms tabs. Role tabs are **ephemeral**:

1. `ensure_terminal()` reuses the handle from `handles.json` when the role's terminal is live; otherwise it recreates + re-seeds the tab. Bootstrap uses the same function, which is what makes it idempotent and resumable. Dispatch therefore works without a prior bootstrap run (except the `handles.json`-exists guard at the top).
2. Every spec gets a `[ROLE=… | model]` prefix, the STANCE line, and an injected `AUTO-CLOSE` block telling the worker to `orca terminal close --terminal <handle> --tab` after `worker_done`.
3. A background `orca-reap-task.sh` polls `dispatch-show` (never `orchestration check`, so it does not consume inbox messages) and closes the tab on `completed|failed`. Belt-and-suspenders with step 2.
4. `dispatch-ledger.jsonl` records `taskId/dispatchId/role/handle` for the reaper and `orca-wait-done.sh`.

**Failure semantics — do not soften these.** They are the whole point of R3–R6:

- `terminal_is_live` is tri-state: `0` live, `1` confirmed gone, `2` unknown. Collapsing 1 and 2 leaks a tab in the reaper and creates a duplicate in `ensure_terminal`.
- `close_terminal()` always attempts a close on unknown liveness. A redundant close is free; a skipped one costs a billable session.
- Anything that could not close, or could not read a status, must exit **non-zero** and write `reap_failed` / `close_failed` to the ledger. `orca-status.sh` is the only surface that shows those rows.
- The reaper never force-closes on timeout or parse failure: the task may still be running, so it reports rather than kills.

`orca-wait-done.sh` is *optional* blocking only — closing does not depend on it. `--no-reap` is the only way to make tabs linger.

## Conventions

- **No `jq`.** All JSON parsing/writing is `python3` heredocs inside Bash. Keep it that way — `python3` is the only declared dependency.
- **Every state write is locked and atomic.** `handles.json` and `dispatch-ledger.jsonl` are mutated concurrently (one background reaper per in-flight dispatch, plus a possible `orca-wait-done.sh`). Use `handles_set` / `handles_set_meta` / `ledger_append` / `ledger_update` in the lib — all take an `fcntl.flock` on a sidecar `.lock` and land via temp + `os.replace`. Never add a bare `open(path, "w")` on these files.
- **Bash 3.2 (macOS default).** No `mapfile`, no associative arrays. Array expansion uses the `"${ARR[@]+"${ARR[@]}"}"` guard for the `set -u` empty-array case.
- `orca-roles-lib.sh` is sourced only and intentionally sets no shell options — callers own `set -euo pipefail`.
- Never commit `.orca/orchestration/handles.json`, `dispatch-ledger.jsonl`, or `reapers/` (the whole `.orca/` tree is gitignored here).
- Default launch commands bypass provider permission checks (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, `--permission-mode bypassPermissions`). This is deliberate and documented; don't silently change it in either direction.

## Slash command duplication

`commands/*.md` (Claude) and `prompts/orca-*.md` (Codex) are near-identical pairs — same body, but the Claude version carries an `allowed-tools:` frontmatter line and says "SKILL.md" where the Codex one says "the skill". Edit both, or the two hosts drift:

| Claude | Codex |
|---|---|
| `commands/install.md` | `prompts/orca-install.md` |
| `commands/bootstrap.md` | `prompts/orca-bootstrap.md` |
| `commands/dispatch.md` | `prompts/orca-dispatch.md` |
| `commands/wait.md` | `prompts/orca-wait.md` |
| `commands/fallback.md` | `prompts/orca-fallback.md` |
| `commands/close.md` | `prompts/orca-close.md` |
