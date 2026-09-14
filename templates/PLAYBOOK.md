# Orca multi-model orchestration playbook

SSOT (managed routing): `.orca/orchestration/roles.yaml`  
User hints: `.orca/orchestration/project_hints.yaml` (yours — installer never overwrites)  
Scripts: [`SCRIPTS.md`](./SCRIPTS.md)

| Role | Model | CLI | Own |
|------|-------|-----|-----|
| **architect** | Claude Opus 5 | `claude` | Design, judgment, high-risk review |
| **executor** | GPT-5.6 Sol | `codex` | Hard implement, terminal loops, verify, close work, raster images via `$imagegen` |
| **thrifty** | Grok 4.5 | `grok` | Small tickets, explore, research, prototypes |
| **ui** | Gemini 3.6 Flash (Medium) | `agy` | User-visible surface, cheap drafts — every draft returns to architect for approval |
| **reviewer** | Claude Opus 5 | `claude` | Final pre-merge gate only — APPROVE/BLOCK, never implements |
| **fallback** | Gemini 3.6 Flash (Medium) | `agy` | **Rate/session limit only** |
| **debater_*** | one seat per provider | claude/codex/grok/agy | Idea debate only — read-only, never implements |

Principle: **Opus deepens, Sol closes, Grok widens.** Limit → agy Flash Medium.

## Personas

Each role's persona is a single-source file in `.orca/orchestration/personas/<role>.md`
(archetype + operating profile). Flow:

- **install** copies `personas/*.md` into the project.
- **bootstrap** seeds each worker with the full persona.
- **dispatch** prepends the file's `<!-- STANCE: … -->` line to every task spec.

Edit the persona file (not the scripts) to tune a role. Missing file → scripts fall back safely.

## Preconditions

```bash
.orca/orchestration/scripts/orca-status.sh   # preflight + roles + leaks, one command
# Settings → Experimental → Agent orchestration ON
```

Exit 0 = ready. Exit 1 prints what is wrong (Orca unreachable, a role CLI missing
from PATH, an unreadable `handles.json`, or a worker tab left open by a failed reap).

Same-checkout work: `orca terminal create --worktree active` (do not invent worktrees).

## Bootstrap

```bash
.orca/orchestration/scripts/orca-bootstrap-roles.sh
# or
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
# subset, when you do not have every role's CLI installed:
.orca/orchestration/scripts/orca-bootstrap-roles.sh --roles architect,executor
```

Idempotent and resumable: a role whose tab is already live is reused, so re-running
after a partial failure finishes the job instead of rebuilding.

Tabs: `role-opus-architect` · `role-sol-executor` · `role-grok-thrifty` · `role-agy-fallback`
(`ui`, `reviewer`, and the `debater_*` seats are created lazily on their first dispatch —
bootstrap only starts the four primaries above.)
Handles: `.orca/orchestration/handles.json` (gitignore).

## Dispatch (supervised)

Only when user asks to supervise / coordinate / wait / DAG:

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan only: …"
.orca/orchestration/scripts/orca-dispatch-role.sh executor  --spec "Implement approved plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty   --spec "Read-only map: …"
.orca/orchestration/scripts/orca-dispatch-role.sh executor  --after task_xxx --spec "…"  # one-off dependency

# Optional: block until result (close is already automatic via reaper)
orca orchestration check --wait --types worker_done,escalation,decision_gate,question --timeout-ms 900000 --json
# or (always pass --task, the task_id printed by dispatch — bare --role can
# act on a leftover message from an unrelated flow, e.g. a debate, and close
# the wrong tab): .orca/orchestration/scripts/orca-wait-done.sh --role thrifty --task task_xxx
```

Role tabs are **ephemeral and released automatically**: every dispatch starts a background reaper (`orca-reap-task.sh`) that calls native `worker-release` once the worker settles, falling back to this package's own close only when Orca reports the tab retained (the common case for a role's pre-created custom-argv terminal). The worker itself never closes its own tab — Orca's contract forbids that. No manual close step. Next dispatch recreates a dead handle automatically. `orca-dispatch-role.sh` refuses to dispatch at all if no Run is bound (see `orca orchestration run-current`/`run-create` above) — a dispatch with no Run can never deliver `worker_done`, so it would only strand a task.

Timeout / `count:0` = checkpoint, not failure if terminal still working. The reaper also watches for a **stalled** worker — status stuck, the worker's own screen unchanged and not busy for several probes — and marks the ledger `stalled`, distinct from a clean `completed`/`failed`. It does **not** close on that alone (Orca's contract forbids releasing on idle state); only the overall reap timeout still escalates (`reap_failed`). A worker deliberately left open on a `decision_gate`, a `question`, or an unclaimed `escalation` (ledger status `awaiting_reply`) is exempt from stall detection.

## DAG dispatch

For a fixed, statically-wireable role chain, wire the whole graph in one shot instead of one blocking dispatch per step:

```bash
.orca/orchestration/scripts/orca-dispatch-dag.sh plan-exec-review "OAuth login"
.orca/orchestration/scripts/orca-dispatch-dag.sh ui "redesign the settings page"
.orca/orchestration/scripts/orca-dispatch-dag.sh explore "map the auth flow before changing it"
```

Every step is created now (`task-create --deps`) so the graph exists in Orca immediately, but only
step 1 (no deps) gets a live worker. Later steps stay `blocked` until their dependency completes —
poll `orca orchestration task-list --ready --json` and dispatch each ready step with:

```bash
.orca/orchestration/scripts/orca-dispatch-existing.sh <task_id> <role>
```

Patterns are defined once in `orca-roles-lib.sh`'s `dag_pattern()` — do not hand-roll the same
chain via three separate `orca-dispatch-role.sh` calls when a pattern already covers it. A step
whose role depends on a PRIOR step's actual output (not just "prior step done") cannot be
pre-wired — that fan-out stays a coordinator-driven `task-list --ready` wave.

## Limit failover

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --check-handle term_…
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from architect --spec "Continue: …"
```

Creates a **new** task with a `[FAILOVER from …]` wrapper spec — deliberately not a same-task
`--retry-of`, because a cross-role retry (e.g. architect → fallback) would deliver the OLD role's
frozen spec text verbatim to the new seat (measured live, see
`references/orca-contract-2026-08-13.md`). For **same-role** crash recovery instead (the role's
own worker vanished mid-task, retry the identical work on a fresh terminal of the same role):

```bash
orca orchestration worker-stop --dispatch <old_dispatch_id> --json   # only after it is confirmed stopped/failed
.orca/orchestration/scripts/orca-dispatch-existing.sh <task_id> <role> --retry-of <old_dispatch_id>
```

## Idea debate

```bash
.orca/orchestration/scripts/orca-debate.sh --topic "…"
.orca/orchestration/scripts/orca-debate.sh --topic "…" --judge architect
.orca/orchestration/scripts/orca-debate.sh --topic "…" --debaters claude,codex,grok
```

propose → critique (anonymized) → converge. Four read-only seats, quorum 3, tabs persist between
rounds and close when the driver exits. Transcript in `debates/<slug>/`; decision in `docs/ideas/`.

A background watchdog (`orca-sweep-orphans.sh --watchdog`, started automatically) closes debater
tabs on its own if the driver is killed or crashes mid-debate, so a lost driver never leaves a
permission-bypassed session running unattended. Run `orca-sweep-orphans.sh` any time to report (or,
with `--close`, close) any other untracked role/debate terminal.

## Recipes

The CLI half of Orca's own recipes (`onorca.dev/docs/recipes`), via the `or` alias.
Steps with no CLI are left to the human and named as such.

```bash
.orca/orchestration/or race start "Fix the login bug" [--roles architect,executor,thrifty] [--base-branch main]
.orca/orchestration/or race status <race_id>          # worker state + change counts per seat
.orca/orchestration/or race pick <race_id> <seat>     # DELETES the other seats' worktrees/branches; opens the winner's diff
.orca/orchestration/or race finish <race_id>          # release the winner's tab; worktree stays for commit/push
.orca/orchestration/or race abort <race_id>           # remove every non-winner seat
.orca/orchestration/or review [sel] [--mode diff|both] [--path f [--staged]] [--race <id> <seat>]
.orca/orchestration/or ps                             # worktrees, live terminals, agents, race seats, needs-input
.orca/orchestration/or gc [--base main] [--close]     # merged worktrees; report-only until --close, never --force
.orca/orchestration/or note "reproduced; testing fix" --workspace-status in-progress   # worktree checkpoint
.orca/orchestration/or fix http://localhost:3000/page # ui tab active + browser on the page, then click in Design Mode
.orca/orchestration/or hosts                          # what --host / --environment selectors exist
```

- **Race** — each seat is a normal supervised dispatch (`task-create` + `worker-start
  --terminal … --worktree path:<seat>`) in its own worktree from `--base-branch`, so it
  shows in `or s`/`or w` like any dispatch. Seats live in `race-ledger.jsonl`, not
  `handles.json`. Tabs are retained until `pick`/`finish`/`abort` because the diff viewer's
  **Send to agent** needs a live agent in that worktree (`--reap` opts back into the reaper).
  Fewer than two seats started → exit 2, run `abort`. Failed seats show in `or s` section [5].
- **Review** — only opening the diff has a CLI; `j`/`k`/`c` and **Send to agent** are UI.
- **Worktrees** — Cmd-J palette, Restart chip and the notification bell are UI; `ps` is the
  coordinator's palette, `gc` is the recipe's "delete merged worktrees aggressively" with a
  report-first default and Orca's own merged-branch guard intact.
- **Design Mode** — the click is UI; `fix` makes sure the attachment lands in the `ui` tab.
- **Remote** — SSH hosts are registered in Settings → SSH; `race start --project <id>
  --host ssh:<id>` passes through to `worktree create` but is untested in this package.

## Routing cheat sheet

| Request | Primary | Secondary |
|---------|---------|-----------|
| Design / ambiguous | architect | — |
| High-risk (auth/PII/security) | architect → executor → architect review | |
| Hard implement / debug | executor | thrifty explore |
| Raster image generate/edit | executor (`$imagegen`) | — (ask user first if brief unclear) |
| Small fix / rename / polish | thrifty | — |
| Map code (read-only) | thrifty | — |
| Research / alternatives | thrifty | architect critique → executor integrate |
| Prototype (code/UI) | thrifty | architect before promote |
| typecheck / build / test | executor | — |
| UI/UX surface, layout, visual draft | ui | architect approval gate |
| Final pre-merge gate | reviewer | — |
| Idea research / brainstorm / find a niche | debate driver | — |

## Image generation clarity gate

Before dispatching image work to executor:

1. Detect intent (generate/edit image, 이미지 생성/편집, mockup photo, hero art, illustration, sprite, product shot, transparent cutout).
2. If **subject** or **intended use** is missing (and destination when project-bound), **ask the user** — do not invent creative requirements.
3. When clear, dispatch executor with a `$imagegen`-only spec (see `dags.image_generate` in `roles.yaml`).
4. Not for SVG/vector icon systems or code-native graphics — keep those on thrifty/executor code paths.

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh executor --spec "
Use Codex \$imagegen skill only.
Goal: …
Subject: …
Use: …
Destination: …
Done: final path(s) + mode
"
```

## Patterns

```text
Plan → Execute → Review:  orca-dispatch-dag.sh plan-exec-review "…"  (architect → executor → reviewer)
Image (clear brief):      executor ($imagegen)
Image (ambiguous brief):  ask user → then executor ($imagegen)
UI surface:               orca-dispatch-dag.sh ui "…"  (ui(draft) → architect(approve) → ui(impl) → reviewer(review))
Explore then build:       orca-dispatch-dag.sh explore "…"  (thrifty(map) → architect(plan) → executor(impl))
Idea debate:              propose → critique (anonymized) → converge → decide
Cost ladder:              thrifty → executor → architect
Limit:                    any primary → fallback (agy), new task + [FAILOVER] wrapper — not --retry-of
Research:                 thrifty → architect → executor
```

## Spec prefix

Scripts auto-prefix: `[ROLE=<role> | <model>]`

Always include project constraints from AGENTS.md / CLAUDE.md in the body.

## Handoff vs supervised

| Phrase | Mode |
|--------|------|
| hand off / 넘겨줘 | full handoff — `terminal send` only (no lifecycle close) |
| supervise / 조율 / DAG / 완료 대기 | supervised — task-create + worker-start (auto-reaper releases the tab) + optional check --wait |

## When something looks wrong

```bash
.orca/orchestration/scripts/orca-status.sh
```

Section 3 lists dispatches that never reached `closed`/`released`. A
`reap_failed` / `close_failed` / `release_unknown` row means the reaper gave
up while the worker tab may still be open and billing — close it with
`orca-close-role.sh <role|term_*>`. `stalled` means the idle probe found a
worker that stopped making progress — the tab is still open (never closed on
idle alone), and the task itself likely never actually reported done, worth a
look regardless. `awaiting_reply` means a worker is correctly idle, waiting on
your reply to a `decision_gate`, a `question`, or an `escalation` — not a leak.
