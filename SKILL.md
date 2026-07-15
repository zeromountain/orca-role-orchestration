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

Portable four-role setup for Orca Agent IDE. Coordinator routes work by model strength; workers report `worker_done` under supervised dispatch.

## Roles (fixed)

| Role | Model | Launch |
|------|-------|--------|
| **architect** | Claude Opus 4.8 | `claude --model claude-opus-4-8 --dangerously-skip-permissions` |
| **executor** | GPT-5.6 Sol | `codex --model gpt-5.6-sol -c model_reasoning_effort="high" --dangerously-bypass-approvals-and-sandbox` |
| **thrifty** | Grok 4.5 | `grok --model grok-4.5 --permission-mode bypassPermissions` |
| **fallback** | Gemini 3.5 Flash (Medium) | `agy --model "Gemini 3.5 Flash (Medium)" --dangerously-skip-permissions` |

Principle: **Opus deepens, Sol closes, Grok widens. Limit → agy Flash Medium.**

Load `references/model-roles.md` only when the user asks why a role was chosen.

Each role's persona lives in `personas/<role>.md` (single source). Bootstrap seeds the
worker with the full persona; dispatch prepends the file's `<!-- STANCE: … -->` line as a
per-task reminder. Missing file → bootstrap uses a built-in one-liner and dispatch omits the reminder.

## Preconditions

```bash
orca status --json   # runtime.reachable true
# Settings → Experimental → Agent orchestration ON
which orca claude codex grok agy
```

If the project is not in Orca: `orca repo add --path <abs-project-root>`.

## Skill layout

```
orca-role-orchestration/
  SKILL.md
  scripts/
    install-to-project.sh      # project scaffold install/update (idempotent)
    install-skill.sh           # global skill clone-or-pull + multi-agent symlinks
    orca-bootstrap-roles.sh
    orca-dispatch-role.sh
    orca-fallback-on-limit.sh
    check-personas.sh          # lint persona skeleton + STANCE (dev/CI)
  templates/                   # copied into project by install
    roles.yaml                 # managed routing (always refreshed)
    project_hints.yaml         # user-owned (create once)
    personas/                  # architect|executor|thrifty|fallback|coordinator .md
  tests/install.sh
  references/model-roles.md
```

Resolve the skill root from this file’s directory. A conventional installation is:

`~/.agents/skills/orca-role-orchestration/`
(Grok may also see `~/.grok/skills/orca-role-orchestration` → symlink)

The default worker launch commands bypass provider permission checks. Use them only
in trusted repositories, or remove the bypass flags before bootstrapping.

## Modes

### A) Install or update (one free re-run command)

**Global skill** (clone-or-pull + symlinks into existing agent skill dirs):

```bash
./scripts/install-skill.sh
# or: curl -fsSL …/install-skill.sh | bash
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

Writes `.orca/orchestration/handles.json`. Re-run after closed tabs / invalid handles. Duplicate tabs possible if old `role-*` tabs still open — close them first when clean slate is needed.

### C) Route + supervised dispatch

Use **supervised** lifecycle only when the user wants coordinate / supervise / wait / DAG / results:

1. Read `.orca/orchestration/roles.yaml` routing_table **and** `.orca/orchestration/project_hints.yaml` (and AGENTS.md).
2. Pick primary role (and secondary if dual path).
3. Dispatch:

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan only: <goal>. Follow AGENTS.md."
.orca/orchestration/scripts/orca-dispatch-role.sh executor  --spec "Implement approved plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty   --spec "Read-only map: …"
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

4. Wait with rolling windows (timeout ≠ failure):

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

5. On rate/session limit:

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role|term_*> --spec "Continue: <goal + partial>"
```

### D) Full handoff (no lifecycle)

If user says hand off / 넘겨줘 without supervise language: do **not** task-create/dispatch/check. Use `orca terminal send` or non-lifecycle worktree handoff only. See generic `orchestration` skill ownership rules.

## Routing cheat sheet

| User need | Role |
|-----------|------|
| Design, ambiguous scope, high-risk review | architect |
| Hard implement, debug, typecheck/build, close PR unit | executor |
| Raster image generate/edit (Codex `$imagegen`) | executor |
| Small fix, map code, research, code prototype | thrifty |
| Primary hit session/rate/quota limit | fallback |

Standard DAG: `architect(plan) → executor|thrifty(impl) → architect(review-only)`.
Image DAG: clarity gate → `executor` (`$imagegen`) only.
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
3. Handles valid or bootstrap
4. Route by roles.yaml + project_hints.yaml (image intent → clarity gate → executor/`$imagegen`)
5. Dispatch --inject → check --wait
6. Limit → fallback script
7. Synthesize worker_done bodies; re-dispatch fixes if needed

## Do not

- Substitute generic subagents for Orca dispatch when user asked for Orca role orchestration
- Use fallback as default quality lane
- Retry a limited primary until its window resets
- Claim orchestration without `task-list` / `dispatch-show` proof after supervised work
- Generate images without a clear brief (ask first) or with non-Codex image tools when `$imagegen` is the path

## Related

- Generic Orca lifecycle: skill `orchestration`
- Project playbook after install: `.orca/orchestration/PLAYBOOK.md`
