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
tests/install.sh              # installer regressions T1–T19
tests/runtime.sh              # runtime scripts R1–R30 against a fake `orca` on PATH
tests/debate.sh               # debate lib + role-lib unit tests (R1–R6, D1–D7), stubbed orca
scripts/check-personas.sh     # persona lint alone (dev/CI; not installed into projects)
shellcheck -S warning scripts/*.sh tests/*.sh tests/fake-orca/orca   # CI's exact form
```

CI (`.github/workflows/ci.yml`) runs repo-lint, install, runtime and shellcheck on
**both macOS and Ubuntu** — Bash 3.2 on macOS is the compatibility floor — with
`fetch-depth: 0` because the installer stamps `git describe --tags`. `tests/debate.sh`
is not in CI; run it by hand when touching `orca-debate*.sh` or `orca-sweep-orphans.sh`.
`.shellcheckrc` already disables SC1091/SC2294/SC2317 with the reasons inline.

No single-test runner. To isolate a case, comment out the other `# --- Tn` / `# --- Rn`
/ `# --- Dn` blocks in that file (note `tests/runtime.sh` and `tests/debate.sh` both
number from R1, so say which file). `tests/install.sh` leaves `/tmp/install-t<N>.out`
behind per case; `tests/runtime.sh` and `tests/debate.sh` `rm -rf` their tmp dirs on
EXIT, so capture output from the run itself.

`tests/runtime.sh` needs no Orca: it puts `tests/fake-orca/` first on `PATH` (a shim,
not a shell function — `orca-dispatch-role.sh` `nohup`s the reaper as a separate
process). Each case installs the scaffold into a tmp project and runs scripts from
there, so every runtime test also asserts the installer's output is runnable.
Failure paths are reachable via `$FAKE_ORCA_STATE/fail/<subcommand>`: create the file
to make that subcommand exit 1, or put `garbage` in it to emit non-JSON.

Three env facts you will hit the first time you run a script by hand instead of via the tests:

- **Run scope.** Every dispatch needs a bound Orca Run. `resolve_run_id()` takes
  `$ORCA_RUN_ID` if set, else `orca orchestration run-current`; with neither, dispatch
  refuses (R13). The test suites export `ORCA_RUN_ID=run_testsuite`.
- **`codex_trust_ensure()` writes to `${CODEX_HOME:-$HOME/.codex}/config.toml`
  unconditionally** whenever a codex-backed role terminal is created. Tests sandbox
  `CODEX_HOME` into their tmp dir; a manual run from an installed path does not.
- **Readiness-gate knobs** (`ROLE_READY_TIMEOUT_SECONDS`, `ROLE_READY_POLL_INTERVAL_SECONDS`,
  `ROLE_READY_MIN_ELAPSED_SECONDS`, `ROLE_READY_STABLE_POLLS`, `ROLE_BUSY_TIMEOUT_SECONDS`,
  `ROLE_SEED_MARKER_RETRIES`, `ROLE_SEED_MARKER_INTERVAL_SECONDS`) default to real-CLI
  boot scale (60s / 300s ceilings). Tests shrink them to seconds; don't copy the test
  values into production defaults.

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

The set of installed scripts is the single `MANAGED_SCRIPTS` string near the top of
`install-to-project.sh`, consumed by three loops (copy, legacy relocation, uninstall).
Adding a runtime script means adding it there — nothing else discovers it. Two
exceptions:

- `scripts/install-skill.sh` and `scripts/check-personas.sh` stay in the skill root and
  are never copied into projects.
- `scripts/orca-or.sh` is **deliberately not in `MANAGED_SCRIPTS`**: it installs one
  level up as `.orca/orchestration/or` (a short alias, no `.sh`), so it resolves
  `SCRIPTS_DIR` two ways — `$HERE/scripts` when installed, `$HERE` when run from the
  repo. The header rule is strict: `or` is routing only; every subcommand `exec`s an
  existing script or one `orca` call, and any decision belongs in the script it routes
  to. `up` (status → Run check → bootstrap) is the one allowed exception. R22 asserts
  `or d …` reaches `worker-start` and unknown subcommands exit non-zero.

## Where role facts actually live

Launch commands and DAG chains are **not** in `roles.yaml`. In executable code each
binding exists in exactly one place — keep it that way:

1. `scripts/orca-roles-lib.sh` → `role_meta()` (title/model/agent), `role_launch_cmd()`,
   and `dag_pattern()` (the three chains `plan-exec-review`, `ui`, `explore`).
   `handles_set()` and bootstrap both consume `role_meta`; they used to restate it and
   had already drifted (T10 guards this).
2. `templates/roles.yaml` (including its `dags:` block), `SKILL.md`, `README.md`, and the
   AGENTS.md snippet in `install-to-project.sh` restate it as **prose** — update for
   accuracy, but nothing parses them.

Consumers override per project via `.orca/orchestration/roles.local.json`
(`role_overrides()`), which `role_meta` / `role_launch_cmd` / `role_cli` all consult.
That file uses `\x1f` as its field separator, not tab: tab is an IFS *whitespace*
character, so bash `read` collapses runs of it and drops leading ones — which silently
shifts every empty field.

`LIMIT_RE` in `scripts/orca-fallback-on-limit.sh` is the only copy of the limit-detection
patterns; the stale mirror in `roles.yaml` was deleted rather than re-synced (syncing
would need a YAML parser this package deliberately does not have).

**Retired model names fail CI.** T11 `git grep`s every tracked file for old model
strings (the patterns are `STALE_RE` in `tests/install.sh`) and excludes only
`docs/superpowers/`, `CHANGELOG.md` and `tests/install.sh` because those record
history. `docs/superpowers/` (specs/plans) is that history — don't rewrite it to match
current code. Changes to managed files get a `CHANGELOG.md` entry; that file is what a
consumer reads to learn what an upgrade overwrote.

## Persona contract

`templates/personas/<role>.md` is the single source for worker seeding. Two consumers read the same file differently:

- `orca-roles-lib.sh:persona_body()` — strips the `# ` H1 and the `<!-- STANCE: … -->` comment, sends the rest as the bootstrap seed. Missing file → hardcoded one-liner from `role_fallback_body()`.
- `orca-dispatch-role.sh` — greps only the `STANCE:` line and prepends it to each task spec. Missing file → no stance line.

`check-personas.sh` enforces the H1, a non-empty STANCE, and ten literal `**Section.**` headings across all nine skeleton roles (`architect`, `executor`, `thrifty`, `fallback`, `coordinator` — which has no worker terminal — and the four `debater_*` seats; `ui`/`reviewer` use a different, later structure by design). Adding a section to one persona means adding it to all nine plus the `SECTIONS` array.

## Installer file policy (what `tests/install.sh` protects)

`install-to-project.sh` is idempotent by design and classifies every destination file:

| Class | Files | Behavior on re-run |
|---|---|---|
| Managed | `roles.yaml`, `PLAYBOOK.md`, `SCRIPTS.md`, `handles.example.json`, `scripts/orca-*.sh`, `or` | Always overwritten; backed up only when content differs |
| User-owned | `project_hints.yaml`, `roles.local.json` | Created once (or by the user); never touched again, including under `--reset` |
| Fork-preserving | `personas/*.md` | Refreshed only if the current sha256 matches the hash recorded in `install-manifest.json`; otherwise preserved. No prior hash → treated as forked (fail-safe) |

`install-manifest.json` is both the version stamp (`git describe --tags`) and the hash ledger that makes fork detection work — never stop writing it. `--reset` is the only escape hatch for forked personas. Removed flags (`--force`, `--update`, `--fresh`, `--migrate-roles`) exit 1 with a pointer to the flagless form; keep that behavior.

`backup_file()` rotates: an existing `.bak` moves to `.bak.1`, `.bak.2`, … before the new one is written, so a fork that survives one upgrade is not lost on the next. `--dry-run` must keep every write behind its guard (it also skips `mkdir`); `--uninstall` removes personas only when they still match the shipped template.

A one-time migration extracts `project:` and `project_hints:` out of a legacy single-file `roles.yaml` into `project_hints.yaml` before the managed refresh (covered by T7).

Regression coverage worth preserving: T2 (re-run produces zero `.bak`), T3 (hints survive), T5 (forked persona survives), T7 (legacy migration), T15 (dry-run writes nothing), T16 (backup rotation), T17 (uninstall keeps user files), T18 (`roles.local.json` survives `--reset`).

## Supervised dispatch lifecycle

`orca-dispatch-role.sh` is the entry point for all supervised work; `orca-bootstrap-roles.sh` only pre-warms tabs. Role tabs are **ephemeral**:

1. `ensure_terminal()` reuses the handle from `handles.json` when the role's terminal is live; otherwise it recreates + re-seeds the tab. Bootstrap uses the same function, which is what makes it idempotent and resumable. Dispatch therefore works without a prior bootstrap run (except the `handles.json`-exists guard at the top). `create_role()` appends the raw create response to `terminal-journal.jsonl` **before** parsing it — that journal, not `handles.json`, is what the orphan sweeper trusts.
2. Every spec gets a `[ROLE=… | model]` prefix and the STANCE line — no more than that. The worker never closes its own tab (Orca's contract forbids it, see `references/orca-contract-2026-08-13.md`); `orca orchestration worker-start` injects the worker's dispatch identity itself, so no RUN SCOPE reminder text is needed either.
3. `worker-start` attaches the task to our pre-created terminal (`orca-dispatch-role.sh`). A background `orca-reap-task.sh` polls `worker-show` (never `orchestration check`, so it does not consume inbox messages) and calls `worker_release_or_close()` (orca-roles-lib.sh) once the worker settles: native `worker-release` first, falling back to this package's own `terminal_close_and_verify` when Orca reports the tab retained — the common case for a role's pre-created custom-argv terminal, not an edge case (measured live, see the reference doc's S1-a).
4. `dispatch-ledger.jsonl` records `taskId/dispatchId/role/handle` for the reaper and `orca-wait-done.sh`.

**Failure semantics — do not soften these.** They are the whole point of R3–R6:

- `terminal_is_live` is tri-state: `0` live, `1` confirmed gone, `2` unknown. Collapsing 1 and 2 leaks a tab in the reaper and creates a duplicate in `ensure_terminal`.
- `terminal_close_and_verify()` always attempts a close on unknown liveness. A redundant close is free; a skipped one costs a billable session.
- Anything that could not close, or could not read a status, must exit **non-zero** and write `reap_failed` / `close_failed` / `release_unknown` to the ledger. `orca-status.sh` is the only surface that shows those rows.
- The reaper never force-closes on timeout, parse failure, **or idle/stall detection** — Orca's contract explicitly forbids releasing a worker "because of a timeout, TUI idle state, heartbeat, status, question, escalation." An idle stall is reported (`stalled`) and polling continues; only the overall `--timeout-ms` backstop escalates (`reap_failed`).

**Race seats are the one other lingering-tab path.** `orca-race.sh` (`or race`) creates one
worktree per role (`worktree create --base-branch`), a role tab *in* that worktree
(`create_role` with `WORKTREE=path:<seat>` — never `ensure_terminal`, since `handles.json`
holds one handle per role), then the normal `task-create` + `worker-start --terminal …
--worktree path:<seat>`. Seats live in `race-ledger.jsonl` (plus a mirrored
`dispatch-ledger.jsonl` row) and their tabs are **retained until `pick`/`finish`/`abort`** —
the diff viewer's "Send to agent" needs a live agent in that worktree; `--reap` opts back
into the reaper. Loser cleanup order is measured, not guessed
(`references/orca-recipes-spike-2026-09-14.md`): `worker-stop` (release refuses an unsettled
worker) → `worker-release` (retained/external is fine) → `worktree rm --force` (closes the tabs,
deletes checkout + branch) → verify with `worktree show`. Only ledger-known, non-main
worktrees are ever removed; a failed rm is `rm_failed` + exit 1 and shows in `orca-status.sh`
section [5]. `orca-sweep-orphans.sh` treats `race-*` titles as ours and protects seats whose
row is `running`/`winner`. Use `path:` worktree selectors everywhere — ids are
`<repoId>::<path>`.

`orca-worktrees.sh gc` has `sweep`'s polarity (report-only, `--close` to act) and never
passes `--force`, so Orca's own merged-branch guard stays in force.

`orca-wait-done.sh` is *optional* blocking only — closing does not depend on it. `--no-reap` is the only way to make tabs linger. `orca-wait-done.sh` also now acks every batch it fully processes (`check --ack <delivery_id>`) — without this, `orchestration check` replays the same FIFO batch forever, which was the root cause of two known defects (a leftover message closing the wrong tab; only one waiter supported at a time).

### DAG dispatch and re-dispatch

`orca-dispatch-dag.sh <pattern> "<goal>"` creates the **whole** chain up front
(`task-create --deps`) but dispatches only step 1. Later steps are blocked tasks; the
coordinator dispatches each one with `orca-dispatch-existing.sh <task_id> <role>` once
`orca orchestration task-list --ready` shows it (R19). A step whose role depends on a
prior step's *output* cannot be pre-wired and belongs to that coordinator-driven wave,
not to `dag_pattern()`.

`orca-dispatch-existing.sh` is also how `orca-fallback-on-limit.sh` retries: `--retry-of
<dispatch_id>` keeps the same task's lineage instead of forking an unrelated task (R20).
Never add a `task-create` to it.

## Idea debate and orphan cleanup

`orca-debate.sh` drives three rounds (propose → critique → converge) via
`orca-debate-round.sh`, with the four `debater_*` tabs held open between rounds
(`--persist`). Round prompt text lives in `orca-debate-lib.sh` only; `roles.yaml`
describes the flow as prose.

- **Anonymity is structural.** The label map (roster + shuffled labels) and per-round
  manifest (real names + task ids) are driver-only state kept *outside* `<debate-dir>`
  — nothing inside the debate dir may reveal which model said what. D3 asserts labels
  are shuffled per debate and that a changed roster cannot reuse a stale map.
- Round exit codes: `0` quorum met (3+ usable outputs), `2` quorum failed, `1` usage.
- Rounds poll `dispatch-show` via `dispatch_status()` (the reaper polls `worker-show`);
  neither touches the orchestration inbox.
- Concurrent drivers serialize through a well-known `mkdir` mutex, not per-slug locks —
  a per-slug scan alone had a TOCTOU hole (see the comment in `orca-debate-lib.sh`).

`orca-sweep-orphans.sh` is two tools with **opposite default polarity** — keep both:

- default (sweep) mode: report-only; `--close` is required to act. It only considers
  handles from `terminal-journal.jsonl` that carry our launch titles, are not a current
  `handles.json` value, and are not held by a fresh debate lock; it never acts on
  `terminal_is_live == 2`.
- `--watchdog` mode (started per debate by `debate_watchdog_start`): a genuinely
  separate process that refreshes the debate lock's heartbeat on the driver's behalf and
  **closes by default** the moment `kill -0 <driver pid>` fails; `--dry-run` opts out.
  `tests/debate.sh` starts real watchdog processes and force-kills them on EXIT.

## Conventions

- **No `jq`.** All JSON parsing/writing is `python3` heredocs inside Bash. Keep it that way — `python3` is the only declared dependency.
- **Every state write is locked and atomic.** `handles.json` and `dispatch-ledger.jsonl` are mutated concurrently (one background reaper per in-flight dispatch, plus a possible `orca-wait-done.sh`). Use `handles_set` / `ledger_append` (both in the lib) for the first write to a row; every later status update inlines its own locked read-modify-write (`orca-reap-task.sh`'s `mark_ledger`, `orca-wait-done.sh`'s `mark_ledger_status` and its own inline close-status block — there is no shared `ledger_update`). All of these take an `fcntl.flock` on a sidecar `.lock` and land via temp + `os.replace`. Never add a bare `open(path, "w")` on these files.
- **Bash 3.2 (macOS default).** No `mapfile`, no associative arrays. Array expansion uses the `"${ARR[@]+"${ARR[@]}"}"` guard for the `set -u` empty-array case.
- `orca-roles-lib.sh` and `orca-debate-lib.sh` are sourced only and intentionally set no shell options — callers own `set -euo pipefail`.
- Never commit anything under `.orca/` (`handles.json`, `dispatch-ledger.jsonl`, `terminal-journal.jsonl`, `reapers/`, `debates/`, `debate-locks/`, `*.lock` — the whole tree is gitignored here).
- Default launch commands bypass provider permission checks (`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, `--permission-mode bypassPermissions`). This is deliberate and documented; don't silently change it in either direction.

## Slash command duplication

`commands/*.md` (Claude) and `prompts/*.md` (Codex) are near-identical pairs — same filename in
both directories now (Claude commands were renamed to match Codex's `orca-*.md` prompts, so a
bare `/orca-dispatch` is unambiguous in Claude Code v2.1.216+ even alongside other installed
plugins), same body, but the Claude version carries an `allowed-tools:` frontmatter line and says
"SKILL.md" where the Codex one says "the skill". Edit both, or the two hosts drift
(`tests/repo-lint.sh` checks the pairing, not the bodies):

| Claude | Codex |
|---|---|
| `commands/orca-install.md` | `prompts/orca-install.md` |
| `commands/orca-bootstrap.md` | `prompts/orca-bootstrap.md` |
| `commands/orca-dispatch.md` | `prompts/orca-dispatch.md` |
| `commands/orca-wait.md` | `prompts/orca-wait.md` |
| `commands/orca-fallback.md` | `prompts/orca-fallback.md` |
| `commands/orca-close.md` | `prompts/orca-close.md` |
| `commands/orca-debate.md` | `prompts/orca-debate.md` |
| `commands/orca-status.md` | `prompts/orca-status.md` |
