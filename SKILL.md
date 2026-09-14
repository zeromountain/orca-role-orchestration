---
name: orca-role-orchestration
description: >
  Install and run Orca multi-model role orchestration: Claude Opus 5 (architect,
  reviewer), GPT-5.6 Sol via Codex (executor), Grok 4.5 (thrifty), Antigravity
  Gemini 3.6 Flash Medium (ui, fallback on rate/session limits). Raster image
  generation/edit routes to executor with Codex $imagegen; if the image brief is
  ambiguous, ask the user first. Also runs a four-model idea debate (Claude, Codex,
  Grok, Gemini propose, critique anonymously, and converge on a niche) for
  brainstorming and idea refinement. Use whenever the user wants model role
  separation in Orca Agent IDE, multi-model routing, role workers, bootstrap roles,
  dispatch by role, plan-execute-review DAGs, image generation / imagegen /
  이미지 생성, limit failover to agy/Gemini Flash, multi-model debate, idea debate,
  or mentions Opus/Sol/Grok role split, orca-role-orchestration, /orca-role-orchestration,
  "역할 오케스트레이션", "모델별 역할 분리", "architect executor thrifty",
  "fallback Gemini Flash", "아이디어 토론", "브레인스토밍", "아이디어 구체화", or
  "니치 찾기". Prefer this skill over ad-hoc multi-agent setup when work should be
  routed by model strengths. Complements the generic `orchestration` skill
  (lifecycle primitives) with a concrete role playbook and installable scaffold.
---

# Orca Role Orchestration

Portable six-role setup for Orca Agent IDE, plus a four-model idea-debate mode. Coordinator routes work by model strength; workers report `worker_done` under supervised dispatch.

## Roles (fixed)

| Role | Model | Launch |
|------|-------|--------|
| **architect** | Claude Opus 5 | `claude --model claude-opus-5 --dangerously-skip-permissions` |
| **executor** | GPT-5.6 Sol | `codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox` |
| **thrifty** | Grok 4.5 | `grok --model grok-4.5 --permission-mode bypassPermissions` |
| **ui** | Gemini 3.6 Flash (Medium) | `agy --model "Gemini 3.6 Flash (Medium)" --dangerously-skip-permissions` |
| **reviewer** | Claude Opus 5 | `claude --model claude-opus-5 --dangerously-skip-permissions` |
| **fallback** | Gemini 3.6 Flash (Medium) | `agy --model "Gemini 3.6 Flash (Medium)" --dangerously-skip-permissions` |
| **debater_{claude,codex,grok,gemini}** | one seat per provider | debate only — read-only, never implements |

Bootstrap starts the four primaries (architect/executor/thrifty/fallback); `ui`, `reviewer`,
and the `debater_*` seats are created lazily on their first dispatch.

Principle: **Opus deepens, Sol closes, Grok widens. Limit → agy Flash Medium.**

A consumer without one of these CLIs can repoint a role without forking any
script: `.orca/orchestration/roles.local.json` (user-owned, never overwritten)
overrides `model`/`launch_command`/`title`/`agent` per role. Role **names**
stay fixed — only their bindings are overridable. See `references/installation.md`.

Load `references/model-roles.md` only when the user asks why a role was chosen.

Each role's persona lives in `personas/<role>.md` (single source). Bootstrap seeds the
worker with the full persona; dispatch prepends the file's `<!-- STANCE: … -->` line as a
per-task reminder. Missing file → bootstrap uses a built-in one-liner and dispatch omits the reminder.

## Preconditions

```bash
.orca/orchestration/scripts/orca-status.sh   # preflight + role CLIs + unclosed dispatches
# Settings → Experimental → Agent orchestration ON

# Run scope (Orca contract update, 2026-07-31) — REQUIRED for any dispatch
orca orchestration run-current --json          # {"run": null} means not bound
orca orchestration run-create --objective "…"  # bind one if null
```

`orca-status.sh` exit 0 = ready; exit 1 names what is wrong (Orca unreachable,
a role CLI missing from PATH, an unreadable `handles.json`, or a worker tab
left open by a failed reap). Run it before diagnosing anything else.

Orca's orchestration CLI verbs have changed contract before without warning
(see the "2026-07-31" Run-scope note above, and `references/orca-contract-*.md`
for the most recent measured snapshot). If a command in this file looks stale
against what the coordinator actually sees, check the live guide rather than
trusting a hardcoded example here: `orca skills get orchestration --full`.

If the project is not in Orca: `orca repo add --path <abs-project-root>`.

**Why the Run matters.** `task-create`, `dispatch`, and `check` are Run-scoped.
With no Run bound they fall through to the retained legacy coordinator, which is
read-only and refuses every mutation with `legacy_read_only` — **no task id is
produced**. The scripts resolve the id automatically (`$ORCA_RUN_ID`, else
`run-current`) and pass `--run`; they never create a Run for you, because
`run-create` rebinds the calling terminal and Runs have no close step.

This reaches the **worker** too. Orca's injected preamble shows a
`orca orchestration send` example with no `--run`, so a worker that copies it
has its `worker_done` refused — the task stays `dispatched` forever even though
the work finished. Every dispatch spec therefore carries a RUN SCOPE block
telling the worker to add `--run` to its own calls. Measured: same role, same
model, same task — `dispatched` without the block, `completed` with it.
`orca-dispatch-role.sh` now refuses outright when no Run resolves, before
`task-create` ever runs — a dispatch with no RUN SCOPE block would only ever
strand a task, so the refusal costs nothing (see "Idle/stalled workers" below
for the case where a dispatch went out before this fix and is stuck already).

Left unbound, the failure is invisible at the point of cause: bootstrap and the
debate preflight both pass, seats seed normally, and the work dies much later as
worker timeouts that look like a model problem. `orca-debate.sh` therefore
refuses up front instead of burning a round.

**Idle/stalled workers.** `orca-reap-task.sh` cannot tell "still working" from
"crashed, rate-limited, or its `worker_done` was refused" from status alone —
that's `dispatched`/`running` in every one of those cases. After a grace
period it also re-reads the worker's own screen, and reports the ledger status
`stalled` once it has sat unchanged, not busy, for several consecutive
probes — it does **not** close the tab on that alone: Orca's contract forbids
releasing a worker "because of a timeout, TUI idle state, heartbeat, status,
question, escalation." The overall reaper timeout (`--timeout-ms`, ledger
`reap_failed`) is the real backstop for a worker that never settles. A worker
the coordinator is deliberately waiting to reply to (`decision_gate`,
`question`, or an unclaimed `escalation` — `orca-wait-done.sh` marks the
ledger row `awaiting_reply`) is exempt: idle detection never fires on it. See
`orca-reap-task.sh --help` for the `--idle-*` knobs.

## Skill layout

```
orca-role-orchestration/
  SKILL.md                     # single skill at plugin root (Claude Code layout)
  .claude-plugin/
    plugin.json                # Claude plugin identity
    marketplace.json           # Claude self-marketplace catalog (source: "./")
  .codex-plugin/
    plugin.json                # Codex plugin identity (skills: "./", hooks: {})
  .agents/plugins/
    marketplace.json           # Codex marketplace catalog (source url "./")
  commands/                    # Claude Code slash commands (auto-discovered)
    orca-install.md orca-bootstrap.md orca-dispatch.md orca-wait.md
    orca-fallback.md orca-debate.md orca-close.md orca-status.md
    orca-race.md orca-review.md orca-worktrees.md orca-design-fix.md   # Orca recipes
    # same filenames as prompts/ below — a bare /orca-dispatch resolves
    # without the plugin namespace prefix (Claude Code v2.1.216+) as long as
    # no other installed plugin claims the same name
  prompts/                     # Codex slash commands (symlinked into $CODEX_HOME/prompts)
    orca-install.md orca-bootstrap.md orca-dispatch.md orca-wait.md
    orca-fallback.md orca-debate.md orca-close.md orca-status.md
    orca-race.md orca-review.md orca-worktrees.md orca-design-fix.md
  scripts/
    install-to-project.sh      # project scaffold install/update (idempotent)
    install-skill.sh           # global skill clone-or-pull + multi-agent symlinks
    orca-bootstrap-roles.sh
    orca-dispatch-role.sh      # recreates dead/missing role tabs
    orca-status.sh             # doctor: preflight, role liveness, unclosed dispatches
    orca-close-role.sh         # manual emergency close
    orca-reap-task.sh          # background auto-close on dispatch complete
    orca-wait-done.sh          # optional blocking wait
    orca-roles-lib.sh          # shared role meta / create / seed / roles.local.json overrides
    orca-fallback-on-limit.sh
    orca-debate.sh              # drive a 3-round four-model idea debate
    orca-debate-round.sh        # one debate round: fan out, poll, collect, lint
    orca-debate-lib.sh          # debate helpers + round prompts (sourced)
    orca-sweep-orphans.sh       # report/close untracked terminals; --persist dead-man watchdog
    orca-race.sh                # recipe: race N roles, one worktree each (start/status/pick/finish/abort)
    orca-review.sh              # recipe: open the diff viewer + print the review keys
    orca-worktrees.sh           # recipe: `ps` (worktrees + agents) / `gc` (merged worktrees)
    orca-design-fix.sh          # recipe: Design Mode fix loop (ui tab active, browser on page)
    check-personas.sh          # lint persona skeleton + STANCE (dev/CI)
  templates/                   # copied into project by install
    roles.yaml                 # managed routing (always refreshed)
    project_hints.yaml         # user-owned (create once)
    personas/                  # architect|executor|thrifty|ui|reviewer|fallback
                                # |coordinator|debater_{claude,codex,grok,gemini} .md
  tests/
    install.sh                 # installer regressions
    runtime.sh                 # runtime scripts against a fake `orca` on PATH
    repo-lint.sh                # manifests, command/prompt pairs, personas
    debate.sh
  references/model-roles.md references/installation.md
  references/orca-recipes-spike-2026-09-14.md   # measured `orca worktree` / worker-start shapes
```

Resolve the skill root from this file’s directory. A conventional installation is:

`~/.agents/skills/orca-role-orchestration/`
(Grok may also see `~/.grok/skills/orca-role-orchestration` → symlink)

**Claude Code plugin marketplace** (self-marketplace; root `SKILL.md` is the single skill):

```text
/plugin marketplace add zeromountain/orca-role-orchestration
/plugin install orca-role-orchestration@orca-role-orchestration
```

Slash commands ship with the plugin (namespace `orca-role-orchestration`). Claude commands and
Codex prompts share the same filename now (`commands/orca-dispatch.md` / `prompts/orca-dispatch.md`),
so the bare form works on both hosts — the namespaced form is the fallback if another installed
plugin claims the same bare name:

| Bare (Claude Code v2.1.216+ / Codex) | Namespaced (Claude Code, always works) | Script |
|---|---|---|
| `/orca-install` | `/orca-role-orchestration:orca-install` | `install-to-project.sh` |
| `/orca-bootstrap` | `/orca-role-orchestration:orca-bootstrap` | `orca-bootstrap-roles.sh` |
| `/orca-dispatch <role> <task>` | `/orca-role-orchestration:orca-dispatch` | `orca-dispatch-role.sh` |
| `/orca-wait` | `/orca-role-orchestration:orca-wait` | `orca-wait-done.sh` |
| `/orca-fallback <role> <goal>` | `/orca-role-orchestration:orca-fallback` | `orca-fallback-on-limit.sh` |
| `/orca-debate <topic>` | `/orca-role-orchestration:orca-debate` | `orca-debate.sh` |
| `/orca-close <role>` | `/orca-role-orchestration:orca-close` | `orca-close-role.sh` (emergency) |
| `/orca-status` | `/orca-role-orchestration:orca-status` | `orca-status.sh` |
| `/orca-race start "<goal>"` | `/orca-role-orchestration:orca-race` | `orca-race.sh` (recipe) |
| `/orca-review [sel]` | `/orca-role-orchestration:orca-review` | `orca-review.sh` (recipe) |
| `/orca-worktrees ps\|gc` | `/orca-role-orchestration:orca-worktrees` | `orca-worktrees.sh` (recipe) |
| `/orca-design-fix <url>` | `/orca-role-orchestration:orca-design-fix` | `orca-design-fix.sh` (recipe) |

Claude Code auto-discovers `commands/` from the plugin root. Codex plugin manifests carry
no prompt field, so `install-skill.sh` symlinks `prompts/*.md` into `$CODEX_HOME/prompts/`
(run it once after `codex plugin add` to get the Codex slash commands).

Namespaced skill: `/orca-role-orchestration:…`. Manifests: `.claude-plugin/plugin.json` + `marketplace.json` (`source: "./"`).

**Codex plugin marketplace** (same repo root; do not move layout):

```bash
codex plugin marketplace add zeromountain/orca-role-orchestration
codex plugin add orca-role-orchestration@orca-role-orchestration
```

Manifests: `.codex-plugin/plugin.json` (`skills: "./"`, `hooks: {}`) + `.agents/plugins/marketplace.json`. Do not move `scripts/` or `templates/` — installers require skill-root layout.

The default worker launch commands bypass provider permission checks. Use them only
in trusted repositories, or remove the bypass flags before bootstrapping.

## Modes

### A) Install or update (one free re-run command)

**Claude Code** — marketplace (discovery + skill load):

```text
/plugin marketplace add zeromountain/orca-role-orchestration
/plugin install orca-role-orchestration@orca-role-orchestration
```

**Codex** — marketplace:

```bash
codex plugin marketplace add zeromountain/orca-role-orchestration
codex plugin add orca-role-orchestration@orca-role-orchestration
```

**Global skill** (clone-or-pull + multi-agent symlinks; preferred for project scaffold path):

```bash
./scripts/install-skill.sh
# or: curl -fsSL …/install-skill.sh | bash
# remove: ./scripts/install-skill.sh --uninstall   # drops our symlinks; keeps the checkout
```

**Project scaffold** — same command for first install and every update:

```bash
SKILL=~/.agents/skills/orca-role-orchestration
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)"
# optional: --project-name my-app
# recovery: --reset   # overwrite forked personas too (always .bak)
```

| Path | Policy |
|------|--------|
| `roles.yaml` | **Managed** — always refreshed to skill template |
| `project_hints.yaml` | **Yours** — created once, never overwritten |
| `personas/*.md` | Refresh if unmodified; skip if locally forked |
| scripts, PLAYBOOK, SCRIPTS | Managed refresh (`.bak` on content change) |
| `install-manifest.json` | Version stamp (`git describe`) + file hashes |

Legacy single-file installs auto-migrate: extract `project` + `project_hints` → `project_hints.yaml`, then refresh managed `roles.yaml`.

Then customize **`project_hints.yaml`** (not `roles.yaml`) and bootstrap workers.

### B) Bootstrap role workers

```bash
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
```

Writes `.orca/orchestration/handles.json`. Supervised role tabs are **ephemeral and auto-released**: each `orca-dispatch-role.sh` starts a background reaper that calls native `worker-release` once the dispatch settles, falling back to this package's own close only when Orca reports the tab retained. Next dispatch recreates a dead handle.

### C) Route + supervised dispatch

Use **supervised** lifecycle only when the user wants coordinate / supervise / wait / DAG / results:

1. Read `.orca/orchestration/roles.yaml` routing_table **and** `.orca/orchestration/project_hints.yaml` (and AGENTS.md).
2. Pick primary role (and secondary if dual path).
3. Dispatch (auto-recreates dead/missing role tabs):

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan only: <goal>. Follow AGENTS.md."
.orca/orchestration/scripts/orca-dispatch-role.sh executor  --spec "Implement approved plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty   --spec "Read-only map: …"
```

Or, for one of the three fixed DAG patterns below, wire the whole chain in one call instead of
one blocking dispatch per step — only the first (dependency-free) step gets a live worker now;
dispatch each later step once ready (`task-list --ready`) via `orca-dispatch-existing.sh`:

```bash
.orca/orchestration/scripts/orca-dispatch-dag.sh plan-exec-review "<goal>"
```

Image generation (only after the clarity gate below):

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh executor --spec "
Use Codex \$imagegen skill only
(read \${CODEX_HOME:-\$HOME/.codex}/skills/.system/imagegen/SKILL.md).
Goal: <one-sentence deliverable>
Subject: …
Use: …
Style: …
Destination: <workspace path or preview-only>
Constraints/Avoid: …
Done: final path(s) + mode (built-in|CLI)
"
```

4. Wait for results if needed (close is already automatic — no extra close step):

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate,question \
  --timeout-ms 900000 --json
```

Timeout / `count:0` = checkpoint, not failure. Tab close does not depend on this wait.

5. On rate/session limit:

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role|term_*> --spec "Continue: <goal + partial>"
```

Creates a **new** task with a `[FAILOVER from …]` wrapper spec — deliberately not `--retry-of`
on the same task, because a cross-role retry would hand the new (fallback) seat the OLD role's
frozen spec text verbatim (measured live, `references/orca-contract-2026-08-13.md`). `--retry-of`
is for **same-role** crash recovery only, via `orca-dispatch-existing.sh <task_id> <role>
--retry-of <old_dispatch_id>` after `worker-stop`/`worker-abandon` confirms the old dispatch is
no longer active.

### D) Full handoff (no lifecycle)

If user says hand off / 넘겨줘 without supervise language: do **not** task-create/dispatch/check. Use `orca terminal send` or non-lifecycle worktree handoff only. See generic `orchestration` skill ownership rules.

### E) Idea debate (four models argue an idea into a niche)

When the user wants to research and sharpen an idea rather than build something:

```bash
.orca/orchestration/scripts/orca-debate.sh --topic "<the idea or question>"
```

Three rounds, four models in parallel each round:

| Round | Phase | What each model does |
|---|---|---|
| R1 | propose | Researches prior art, proposes 2-3 ideas, names its own weakest link |
| R2 | critique | Attacks the other three proposals **anonymized**, ranks them, proposes merges |
| R3 | converge | Narrows to 1-2 niche candidates with kill conditions and a first experiment |

Proposals circulate under labels (e.g. Proposal A-D), never model names — a model that knows
"Opus wrote this" defers instead of arguing. Round output is written under its label from the
start (`round-1/A.md`, never a model-named file), labels are shuffled per debate (not derived
from `--debaters` order), and the label map + per-round manifest live outside the debate
directory entirely — only the driver (`orca-debate.sh`/`orca-debate-round.sh`) ever reads them.

**Honest limit:** this is not cryptographic. The guarantee is that nothing instructs a debater
to deanonymize, and no single `diff`, `glob`, or file read *inside the debate directory* reveals
authorship. Debaters run under the same permission-bypass CLI flags as every other role (see
`role_launch_cmd`), so a debater that went off-script could still read `dispatch-ledger.jsonl`,
`handles.json`, `terminal-journal.jsonl`, or `orca terminal list` titles — none of which are
inside the debate directory, none of which any spec ever points a debater at, but none of which
are cryptographically hidden either.

Outputs: `.orca/orchestration/debates/<slug>/transcript.md` (local, gitignored). Then write the
decision to `docs/ideas/<date>-<slug>.md` with `## Decision` / `## Runner-up` / `## Dissent`,
or pass `--judge architect` to have a separate Opus tab write it. The transcript is the one place
a debater's real short name (e.g. "claude") is re-attributed for the human reader — it is written
only after the debate concludes and no round spec ever points a debater at it.

Debaters are **read-only by prompt, not by sandbox** — their dispatch spec and persona instruct
them to write only their own round output file, but nothing in the CLI enforces that. Quorum is 3 —
if two or more fail, the round stops. Round prompt text lives in `scripts/orca-debate-lib.sh`.

Only one debate may run at a time: starting a second one — same slug or a different one — while a
debate is still live is refused (`ensure_terminal` reuses each role's terminal globally, so two
concurrent debates would otherwise dispatch into the SAME four agent sessions; a same-slug
collision would also reset the live debate's tracked handles out from under it).

### F) Recipes (Orca docs → one `or` subcommand each)

Orca's own recipes (`onorca.dev/docs/recipes/*`) are written as GUI steps. This mode is the
CLI half of each, driven from the coordinator via the short `or` alias
(`.orca/orchestration/or`). What has no CLI stays with the human and is said so:

| Recipe | `or …` | UI-only remainder |
|---|---|---|
| Race three agents on the same task | `race start "<goal>" [--roles a,b,c]` → `race status` → `race pick <id> <seat>` → `race finish <id>` | reading the diffs, Annotate AI Diff, commit/push/PR |
| Review an AI diff line-by-line | `review [sel] [--mode diff\|both] [--path f]` | `j`/`k`/`c`, **Send to agent** |
| Jump between 10 worktrees | `ps`, `gc [--close]`, `note "<text>" [--workspace-status id]` | Cmd-J palette, Restart chip, notification bell |
| Fix a UI bug with Design Mode | `fix <url>` → (click) → `fix --verify` | Design Mode toggle + element click |
| Work on a remote machine over SSH | `hosts`; `race start --project <id> --host ssh:<id>` (untested) | Settings → SSH host registration |

**Race rules.** Every seat is a normal supervised dispatch (task-create + `worker-start
--terminal … --worktree path:<seat>`), so it shows in `or s` / `or w`. Seats bypass
`handles.json` (one handle per role cannot hold N seats) and live in `race-ledger.jsonl`.
Seat tabs are **retained after they settle** — the diff viewer's "Send to agent" needs a live
agent in that worktree — until `pick`/`finish`/`abort`; `--reap` opts back into the reaper.
`pick` deletes the losers' worktrees, tabs and branches (`worktree rm --force`): confirm the
seat with the user first. Only ledger-known, non-main worktrees are ever removed. Failed
seats (`start_failed`, `rm_failed`, `close_failed`) show in `or s` section [5].

**gc rules.** Report-only until `--close`; never `--force`; skips the main worktree, the
current directory's worktree and any worktree with live terminals. Same polarity as `sweep`.

## Routing cheat sheet

| User need | Role |
|-----------|------|
| Design, ambiguous scope, high-risk review | architect |
| Hard implement, debug, typecheck/build, close PR unit | executor |
| Raster image generate/edit (Codex `$imagegen`) | executor |
| Small fix, map code, research, code prototype | thrifty |
| UI/UX surface, layout, styling, visual draft | ui |
| Final pre-merge gate (after architect sign-off) | reviewer |
| Idea research, brainstorm, find a niche | debate driver |
| Primary hit session/rate/quota limit | fallback |

Standard DAG: `orca-dispatch-dag.sh plan-exec-review "<goal>"` — architect(plan) → executor(impl) → reviewer(gate).
Explore-then-build DAG: `orca-dispatch-dag.sh explore "<goal>"` — thrifty(map) → architect(plan) → executor(impl).
Image DAG: clarity gate → `executor` (`$imagegen`) only.
UI DAG: `orca-dispatch-dag.sh ui "<goal>"` — ui(draft) → architect(approve) → ui(impl) → reviewer(review).
Cost ladder: `thrifty → executor → architect`.

## Image generation (Codex `$imagegen`)

When the user wants a **new or edited raster image** (hero, mockup photo, illustration, sprite, product shot, transparent cutout, etc.):

1. **Route to executor (Codex)** — never thrifty/Grok or Claude image tools for these tasks.
2. **Clarity gate (coordinator, before dispatch):** if the brief is missing success-critical slots, **ask the user first**. Do not invent brand names, extra subjects, or marketing copy.

| Slot | Ask when missing |
|------|------------------|
| Subject | what is in the frame |
| Intended use | hero, ad, sprite, preview-only, … |
| Destination | project path vs preview-only (if project-bound) |
| Style / constraints | only if user cares (medium, palette, no text, aspect) |
| Edit target | for edits: which file + what must stay unchanged |

If the request is already specific enough, skip questions and dispatch.

3. **Spec must require** Codex skill `$imagegen` only (`${CODEX_HOME:-$HOME/.codex}/skills/.system/imagegen/SKILL.md`). Built-in path by default; CLI fallback only after user confirmation.
4. **Not `$imagegen`:** extending SVG/vector icon sets, logos that must match repo-native vectors, simple shapes better done in HTML/CSS/SVG.

## Spec hygiene

Scripts auto-prefix `[ROLE=<role> | <model>]`. Body should include:

- Goal (one sentence end state)
- Constraints (from AGENTS.md / product guardrails)
- Allowed file scope
- Done definition / verification commands

Image specs: subject, use, destination, constraints/avoid, `$imagegen`-only mandate.

Edit ownership: one role edits a file set at a time; review-only architect does not bulk rewrite.

## Coordinator checklist

1. `orca status --json` ready
2. Scaffold present (`roles.yaml` + `project_hints.yaml` + scripts) or re-run install
3. Handles valid or bootstrap (dispatch also recreates dead tabs)
4. Route by roles.yaml + project_hints.yaml (image intent → clarity gate → executor/`$imagegen`)
5. Dispatch via `orca-dispatch-role.sh` (auto-reaper releases the worker on settle — no manual close)
6. Limit → fallback script
7. Synthesize worker_done bodies; re-dispatch fixes if needed

## Do not

- Substitute generic subagents for Orca dispatch when user asked for Orca role orchestration
- Use fallback as default quality lane
- Retry a limited primary until its window resets
- Claim orchestration without `task-list` / `dispatch-show` proof after supervised work
- Generate images without a clear brief (ask first) or with non-Codex image tools when `$imagegen` is the path
- Pass `--no-reap` unless you intentionally want tabs to linger
- Run `or race pick` / `or gc --close` without the user confirming which worktrees go — both delete checkouts and branches
- Delete race worktrees by hand (`orca worktree rm`) — the race ledger is what makes `pick`/`abort` safe

## Exit-on-done (automatic)

Supervised workers must not linger after a task. Release is **automatic** on every `orca-dispatch-role.sh`:

1. **Background reaper** (`orca-reap-task.sh`) polls `worker-show` and runs `worker-release` when the worker settles (`succeeded`/`failed`), falling back to this package's own close only when Orca reports the tab retained (the common case for a role's pre-created custom-argv terminal — see `references/orca-contract-2026-08-13.md`). Does not consume inbox messages. It also detects a **stalled** worker (status stuck, screen unchanged, not busy) after a grace period and reports it — never closes on that alone, see "Idle/stalled workers" above.
2. The worker never closes its own tab — Orca's contract forbids it. It sends `worker_done` once, then idles.
3. Next dispatch recreates a live terminal if the handle is dead/missing.

Opt out only with `--no-reap`. Manual emergency: `orca-close-role.sh <role|term_*>`.

## Related

- Generic Orca lifecycle: skill `orchestration`
- Project playbook after install: `.orca/orchestration/PLAYBOOK.md`
