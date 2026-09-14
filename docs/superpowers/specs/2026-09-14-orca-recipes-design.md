# Orca recipes as coordinator commands — design

Date: 2026-09-14
Status: implemented in the same change (scripts, tests, docs); remote path left open
Topic: the five pages under `onorca.dev/docs/recipes/*` → one `or` subcommand each

## Problem

Orca's own recipes — race three agents, review an AI diff line-by-line, jump between ten
worktrees, fix a UI bug with Design Mode, work on a remote machine — are written as GUI
steps. A deep-research pass over the five pages (105 agents, 22 sources, 21 confirmed
claims, 4 refuted) found **no `orca` CLI invocation on any of them**. This package, which is
the coordinator's only scripted surface for Orca, had never called `orca worktree`,
`orca file`, `orca goto` or `terminal switch`. So the recipes were things a human did in the
app while the coordinator watched.

What made it tractable: the shipped binary's `orca agent-context --json` (234 commands,
v1.4.202) documents more than the website — `--base-branch` on `worktree create`, the
`path:` selector, and `worker-start`'s own note "when reusing `--terminal`, pass `--worktree`
for that terminal" — and a live spike (`references/orca-recipes-spike-2026-09-14.md`)
settled the receipt shapes and the destructive-operation ordering.

## Goal

Give each recipe the largest CLI-driven core it can honestly have, as one `or` subcommand
plus a slash-command pair, and name the UI-only remainder in the command's own output so
the coordinator hands over instead of pretending.

## Non-goals

- Automating steps that have no CLI: Annotate AI Diff comments and **Send to agent**, the
  Design Mode click, the Cmd-J Jump Palette / Restart chip / notification bell, and
  Settings → SSH host registration. The research checked the recipe pages, the feature
  pages, the full CLI reference and the bundled skill stubs; none exposes these.
- The native `worker-start --worktree new-top-level --agent <claude|codex|cursor>` path.
  It is one call and Orca would own (and close) the tab, but `--agent` accepts three
  providers and this package's ten roles map onto two of them (`role_meta`): a race that
  cannot seat Grok or Gemini is not the recipe. It remains a possible optimization for
  claude/codex seats.
- Publishing an Orca-registry stub (`skills/<name>/SKILL.md`, installed with
  `npx skills add … --skill <name>`). The user chose to extend this repo.

## 1. Recipe → surface map

| Recipe | CLI core (`or …`) | UI-only remainder |
|---|---|---|
| Race three agents on the same task | `race start "<goal>" [--roles a,b,c] [--base-branch ref]`, `race status`, `race pick <id> <seat>`, `race finish <id>`, `race abort <id>` | comparing the diffs, Annotate AI Diff, commit/push/PR |
| Review an AI diff line-by-line | `review [sel] [--mode diff\|both\|edit] [--path f [--staged]] [--race <id> <seat>]` → `orca file open-changed` / `orca file diff` | `j`/`k`/`c`, **Send to agent** (bindable only under Settings → Shortcuts) |
| Jump between 10 worktrees | `ps` (`worktree ps --json` + race seats + `worker-show` `observation.agentWait`), `gc [--base ref] [--close]`, `note "<text>" [--status id]` (`worktree set --comment --workspace-status`) | Cmd-J palette, Restart chip (`terminal create --worktree <sel> --command <launch>` is the manual equivalent), notification bell |
| Fix a UI bug with Design Mode | `fix <url>` → `ensure_terminal ui` + `terminal switch` + `goto --url`; `fix --verify` → `screenshot` | Design Mode toggle + element click (attaches to the *active* agent terminal) |
| Work on a remote machine over SSH | `hosts` (`host list --json`); `race start --project <id> --host ssh:<id>` pass-through | Settings → SSH; `worker-start` has no `--host` (`--on` is paired-server only) |

## 2. Race (`scripts/orca-race.sh`)

### 2.1 Seat sequence

For each role `i` in `--roles` (default `architect,executor,thrifty` — three providers):

1. `orca worktree create --name <slug>-<i> --base-branch <ref> --repo path:<project> --json`.
   The raw receipt is journaled to `race-ledger.jsonl` (`kind=worktree_create`) *before*
   parsing, for the same reason `create_role` journals terminal creates. Parse
   `result.worktree.{id,path,branch}`; fall back to `worktree list --json` matched by name.
   `--base-branch` defaults to the project checkout's current branch — the recipe's "same
   start-from ref" is guaranteed, not assumed.
2. `codex_trust_ensure "<seat path>"` for codex seats — `create_role` only registers the
   project root (its documented LIMITATION), and a codex seat boots in the new checkout.
3. `WORKTREE="path:<seat>"`; `create_role "race-<id>-<role>" "$(role_launch_cmd)"` →
   `wait_idle` → `seed` → `terminal_wait_ready`. **Never `ensure_terminal`/`handles_set`**:
   `handles.json` is one handle per role and N seats of one role would collide.
4. `task-create --run <run> --spec "$(build_role_spec …)"` (STANCE prefix + a seat note:
   work only inside this worktree), then
   `worker-start --run <run> --task <t> --terminal <h> --worktree path:<seat>`.
5. `race-ledger.jsonl` seat row (`kind=seat`, raceId, seat, role, worktreeId, path, branch,
   baseRef, handle, taskId, dispatchId, status=running) **and** a `dispatch-ledger.jsonl`
   row via `register_dispatch_and_reap` — reaper only under `--reap`.
6. `worktree set --comment "race <id> seat i/n: <role>"` so the seat is labelled in the
   sidebar and palette (the checkpoints feature, reused).

Any step failing records `status=start_failed` with whatever was created (path, handle,
task) and moves on. Fewer than two started seats → exit 2 (debate's quorum rule).

### 2.2 Retained tabs (a deliberate second exception)

The package's rule is that role tabs are ephemeral and `--no-reap` is the only way to make
one linger. Race seats are the second: their tab stays open after the worker settles until
`pick`/`finish`/`abort`, because the recipe's review step (Annotate AI Diff → "Send to
agent") needs a live agent *in that worktree*. `--reap` restores the reaper. This is written
into CLAUDE.md's lifecycle section, not just here.

### 2.3 pick / finish / abort — measured ordering

Spike S4 measured, on v1.4.202:

- `worker-release` on an unsettled worker → `dispatch_inactive` error ("use worker-stop").
- `worktree rm --force` with live terminals → `removed:true`; the tabs close, the checkout
  and its branch are deleted; the dispatch settles as `failed`.
- `worker-stop` on a settled worker → `alreadySettled:true`, exit 0 (idempotent).

So a losing seat is `worker-stop` → `worker-release` (retained/external is fine) →
`worktree rm --force` → `worktree show` must fail (verify) → `status=removed`, and its
`dispatch-ledger.jsonl` row is marked `closed`. Guards: only ledger-known paths; never a path
Orca reports as `isMainWorktree`; never the project root. A failed rm is `rm_failed` and
exit 1 — `pick` can be re-run to retry. `finish` releases the winner's tab with
`worker_release_or_close` (the package's normal retained → fallback-close path) and keeps
the worktree for commit/push. `abort` removes every seat that is not the winner unless
`--include-winner`.

### 2.4 What the sweeper and the doctor see

`orca-sweep-orphans.sh` matched only `role_meta` titles, so a crashed race would have left
invisible `race-*` tabs. It now accepts the `race-` prefix and reads `race-ledger.jsonl`:
seats with `running`/`winner` rows are tracked (alive by design); any other race-titled
journal entry is a candidate like a role tab. `orca-status.sh` gained section [5]: open
seats, with `start_failed`/`rm_failed`/`close_failed` counted as problems.

## 3. Thin recipes

- **`orca-review.sh`** — selector default `active`; `--race <id> <seat>` resolves the seat
  path from the ledger and prints its worker state. Opens with `file open-changed --mode` or
  `file diff <path> [--staged]`, then prints the key cheat sheet. Nothing else has a CLI.
- **`orca-worktrees.sh ps`** — `worktree ps --json` rows (path, branch, main, live terminal
  count, agents, comment/status) joined with race seats; `worker-show` `observation.agentWait`
  non-null prints as `needs-input` (the recipe's yellow dot).
- **`orca-worktrees.sh gc`** — main worktree and branch from `worktree list --json`
  (`repo show` exposes no base ref); `git -C <main> branch --merged <base>`; candidates are
  non-main rows whose branch is in that set. Skips the current directory's worktree
  (`worktree current`) and any with live terminals (`terminal list --worktree path:…`).
  Report-only until `--close`; `worktree rm` **without** `--force` so Orca's own
  "cannot prove merged" branch guard applies. Same polarity as `sweep`.
- **`orca-design-fix.sh`** — `ensure_terminal ui` (creates + seeds on first use),
  `terminal switch` to make it the active terminal, `goto --url`, print the UI steps;
  `--verify` runs `screenshot`.
- **`or note` / `or hosts`** — single `orca` calls, so they `exec` from the router directly
  (the router's own rule).

## 4. Files

New: `scripts/orca-race.sh`, `scripts/orca-review.sh`, `scripts/orca-worktrees.sh`,
`scripts/orca-design-fix.sh`; `commands/` + `prompts/` `orca-race.md`, `orca-review.md`,
`orca-worktrees.md`, `orca-design-fix.md`; `references/orca-recipes-spike-2026-09-14.md`.
Changed: `scripts/orca-or.sh` (routes), `scripts/install-to-project.sh` (`MANAGED_SCRIPTS`,
gitignore `race-ledger.jsonl`, AGENTS.md line), `scripts/orca-sweep-orphans.sh`,
`scripts/orca-status.sh`, `tests/fake-orca/orca` (worktree/file/host/goto/screenshot/
switch/worker-stop arms; `terminal list --worktree`), `tests/runtime.sh` (R23–R30),
`tests/install.sh` (T19), `SKILL.md` (Mode F), `templates/PLAYBOOK.md`, `templates/SCRIPTS.md`,
`README.md`, `CLAUDE.md`, `CHANGELOG.md`.

## 5. Verification

- `tests/runtime.sh` R23 (start: 3 creates with `--base-branch`, 3 tabs in seat worktrees,
  3 scoped `worker-start`s, ledgers, `handles.json` untouched, no reaper, checkpoint comment),
  R24 (one failed seat → `start_failed`, quorum exit 2), R25 (pick: stop/release/rm per
  loser, winner kept + diff opened + in-review; finish closes only the tab), R26 (rm failure →
  `rm_failed`, exit 1, reported by the doctor, retry succeeds), R27 (gc report vs `--close`,
  no `--force`, skips busy/unmerged/main), R28 (review), R29 (fix: lazy ui tab, switch before
  goto, reuse), R30 (note/hosts routing; race refuses with no Run).
- `tests/install.sh` T19 (scripts executable, gitignore entry once, `or` routes race).
- Live spike S1–S6 on this machine (see the reference doc); a full live race was not run
  because the seats' first prompt already reproduced the known bypass-permissions dialog
  race, which `seed`/`terminal_wait_ready` exist to gate — the script goes through them.

## 6. Open questions

- **Remote seats.** `race start --project <id> --host ssh:<id>` forwards to
  `worktree create`, but this machine's `host list` has only `local`, so the SSH path is
  unverified, and whether `worker-start --terminal … --worktree path:<remote path>` accepts a
  remote seat is unknown ("remote current and new-child are invalid; discover an exact
  remote selector").
- **Startup terminal.** `worktree create` without `--agent` still opens an inert "Terminal 1"
  tab in the new worktree (not in the JSON on this version). The script leaves it; `rm`
  removes it. Closing it eagerly would save a tab per seat.
- **`gc` without `--force`** on a merged branch was not exercised live; the help text says
  Orca keeps branches it cannot prove merged.
- **Native seats** for claude/codex roles (`--agent --model`, Orca-owned tab) as a later
  optimization; would need a second code path and the ledger to record which kind a seat is.
