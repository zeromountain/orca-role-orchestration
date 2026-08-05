---
name: orca-role-orchestration
description: >
  Install and run Orca multi-model role orchestration: Claude Opus 4.8 (architect),
  GPT-5.6 Sol via Codex (executor), Grok 4.5 (thrifty), Antigravity Gemini 3.5 Flash
  Medium (fallback on rate/session limits). Raster image generation/edit routes to
  executor with Codex $imagegen; if the image brief is ambiguous, ask the user first.
  Use whenever the user wants model role separation in Orca Agent IDE, multi-model
  routing, role workers, bootstrap roles, dispatch by role, plan-execute-review DAGs,
  image generation / imagegen / 이미지 생성, limit failover to agy/Gemini Flash,
  or mentions Opus/Sol/Grok role split, orca-role-orchestration, /orca-role-orchestration,
  "역할 오케스트레이션", "모델별 역할 분리", "architect executor thrifty", or
  "fallback Gemini Flash". Prefer this skill over ad-hoc multi-agent setup when work
  should be routed by model strengths. Complements the generic `orchestration` skill
  (lifecycle primitives) with a concrete four-role playbook and installable scaffold.
---

# Orca Role Orchestration

Portable four-role setup for Orca Agent IDE. The coordinator routes work by model
strength; workers report `worker_done` under supervised dispatch and their tabs
close automatically.

## Roles

| Role | Model | Owns |
|------|-------|------|
| **architect** | Claude Opus 4.8 (`claude`) | Design, ambiguous scope, high-risk review |
| **executor** | GPT-5.6 Sol (`codex`) | Hard implementation, debug, verification, raster images |
| **thrifty** | Grok 4.5 (`grok`) | Small fixes, code maps, research, prototypes |
| **fallback** | Gemini 3.5 Flash Medium (`agy`) | Continuity after a rate/session limit only |

**Opus deepens, Sol closes, Grok widens. Limit → agy Flash Medium.**

Launch commands live in `scripts/orca-roles-lib.sh` (`role_meta` / `role_launch_cmd`) —
the single source. A consumer repoints a role via `.orca/orchestration/roles.local.json`
without forking anything; see `references/installation.md`.

Each role's persona is `personas/<role>.md`. Bootstrap seeds the full persona;
dispatch prepends that file's `<!-- STANCE: … -->` line as a per-task reminder.

## Preconditions

```bash
.orca/orchestration/scripts/orca-status.sh   # preflight + roles + unclosed dispatches
# Settings → Experimental → Agent orchestration ON
```

Exit 0 = ready. Exit 1 names the problem. If the project is not in Orca:
`orca repo add --path <abs-project-root>`. If the scaffold is missing, install it
(mode A). Run this before diagnosing anything else.

## Commands

| Claude Code | Codex | Script |
|-------------|-------|--------|
| `/orca-role-orchestration:install` | `/orca-install` | `install-to-project.sh` |
| `/orca-role-orchestration:bootstrap` | `/orca-bootstrap` | `orca-bootstrap-roles.sh` |
| `/orca-role-orchestration:dispatch <role> <task>` | `/orca-dispatch` | `orca-dispatch-role.sh` |
| `/orca-role-orchestration:status` | `/orca-status` | `orca-status.sh` |
| `/orca-role-orchestration:wait` | `/orca-wait` | `orca-wait-done.sh` |
| `/orca-role-orchestration:fallback <role> <goal>` | `/orca-fallback` | `orca-fallback-on-limit.sh` |
| `/orca-role-orchestration:close <role>` | `/orca-close` | `orca-close-role.sh` (emergency) |

## Modes

### A) Install or update

One flagless command, safe to re-run. `--dry-run` previews, `--reset` recovers,
`--uninstall` removes. Marketplace and layout detail: `references/installation.md`.

```bash
SKILL=~/.agents/skills/orca-role-orchestration
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)"
```

Customize `project_hints.yaml` (never `roles.yaml` — it is managed and gets
overwritten on every update).

### B) Bootstrap role workers

```bash
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
# subset, when you lack a role's CLI:
.orca/orchestration/scripts/orca-bootstrap-roles.sh --roles architect,executor
```

Idempotent and resumable — a live role is reused, so re-running after a partial
failure finishes the job. Role tabs are ephemeral: dispatch recreates a dead one.

### C) Route + supervised dispatch

Use the supervised lifecycle **only** when the user wants coordinate / supervise /
wait / DAG / results.

1. Read `roles.yaml` `routing_table` **and** `project_hints.yaml` (and AGENTS.md).
2. Pick the primary role (see the cheat sheet below; detail in `references/routing.md`).
3. Dispatch — dead tabs are recreated automatically:

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan only: <goal>. Follow AGENTS.md."
.orca/orchestration/scripts/orca-dispatch-role.sh executor  --spec "Implement approved plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty   --spec "Read-only map: …"
```

4. Wait for results only if you need the body — closing does not depend on it:

```bash
orca orchestration check --wait --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

Timeout or `count:0` is a checkpoint, not a failure.

5. On a rate/session limit:

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role|term_*> --spec "Continue: <goal + partial>"
```

### D) Full handoff (no lifecycle)

If the user says hand off / 넘겨줘 without supervise language: do **not**
task-create / dispatch / check. Use `orca terminal send` or a non-lifecycle
worktree handoff. See the generic `orchestration` skill's ownership rules.

## Routing cheat sheet

| User need | Role |
|-----------|------|
| Design, ambiguous scope, high-risk review | architect |
| Hard implement, debug, typecheck/build, close a PR unit | executor |
| Raster image generate/edit (Codex `$imagegen`) | executor |
| Small fix, map code, research, prototype | thrifty |
| Primary hit a session/rate/quota limit | fallback |

Standard DAG: `architect(plan) → executor|thrifty(impl) → architect(review-only)`.
Cost ladder: `thrifty → executor → architect`.

Full routing table, DAG catalog, and edit-ownership rules: `references/routing.md`.

## Image generation

Raster image work routes to **executor** with Codex `$imagegen` only. Before
dispatching, apply the clarity gate: if subject, intended use, or destination is
missing, **ask the user** — do not invent brand names or copy.

Full gate, spec template, and exclusions: `references/image-generation.md`.

## Spec hygiene

Scripts auto-prefix `[ROLE=<role> | <model>]` and append the AUTO-CLOSE contract.
Your spec body should carry:

- Goal — one sentence, the end state
- Constraints — from AGENTS.md / product guardrails
- Allowed file scope
- Done definition / verification commands

One role edits a given file set at a time; a review-only architect does not bulk-rewrite.

## Exit-on-done (automatic)

Close is automatic on every dispatch, two ways: a background reaper polls
`dispatch-show` and closes on `completed|failed`, and an AUTO-CLOSE block injected
into the spec has the worker close its own tab after `worker_done`. Opt out only
with `--no-reap`.

If a reaper cannot read the status or a close fails, it records `reap_failed` /
`close_failed` and exits non-zero rather than pretending success — surface those
with `orca-status.sh` and close manually with `orca-close-role.sh`.

## Do not

- Substitute generic subagents for Orca dispatch when the user asked for Orca role orchestration
- Use fallback as the default quality lane, or retry a limited primary before its window resets
- Claim orchestration without `task-list` / `dispatch-show` proof after supervised work
- Generate images without a clear brief, or with non-Codex tools when `$imagegen` is the path
- Edit `roles.yaml` to customize (managed — use `project_hints.yaml` / `roles.local.json`)
- Pass `--no-reap` unless you intend tabs to linger

## Related

- `references/installation.md` — layout, marketplaces, update policy, role overrides
- `references/routing.md` — full routing table, DAG catalog, failover
- `references/image-generation.md` — `$imagegen` clarity gate and spec
- `references/model-roles.md` — why each model holds its role
- `.orca/orchestration/PLAYBOOK.md` — installed project playbook
- Generic Orca lifecycle: skill `orchestration`
