---
name: orca-role-orchestration
description: >
  Install and run Orca multi-model role orchestration: Claude Opus 4.8 (architect),
  GPT-5.6 Sol via Codex (executor), Grok 4.5 (thrifty), Antigravity Gemini 3.5 Flash
  Medium (fallback on rate/session limits). Use whenever the user wants model role
  separation in Orca Agent IDE, multi-model routing, role workers, bootstrap roles,
  dispatch by role, plan-execute-review DAGs, limit failover to agy/Gemini Flash,
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
    install-to-project.sh      # scaffold into any repo
    orca-bootstrap-roles.sh
    orca-dispatch-role.sh
    orca-fallback-on-limit.sh
    check-personas.sh          # lint persona skeleton + STANCE (dev/CI)
  templates/                   # copied into project by install
    personas/                  # architect|executor|thrifty|fallback|coordinator .md
  references/model-roles.md
```

Resolve the skill root from this file’s directory. A conventional installation is:

`~/.agents/skills/orca-role-orchestration/`
(Grok may also see `~/.grok/skills/orca-role-orchestration` → symlink)

The default worker launch commands bypass provider permission checks. Use them only
in trusted repositories, or remove the bypass flags before bootstrapping.

## Modes

### A) Install scaffold into current project (first time or new repo)

```bash
SKILL=~/.agents/skills/orca-role-orchestration
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)"
# optional: --project-name my-app --force
```

Creates:

- `.orca/orchestration/roles.yaml` (SSOT)
- `.orca/orchestration/PLAYBOOK.md`, `SCRIPTS.md`, `handles.example.json`
- `scripts/orca-{bootstrap-roles,dispatch-role,fallback-on-limit}.sh`
- gitignores `handles.json`; appends short AGENTS.md section if AGENTS.md exists

Then customize `project_hints` in `roles.yaml` and merge AGENTS.md constraints into routing.

Update an existing install (adds personas, refreshes scripts/docs, preserves your `roles.yaml`):

```bash
"$SKILL/scripts/install-to-project.sh" --project-root "$(pwd)" --update
# add --migrate-roles to also convert legacy inline personas to persona_file refs (roles.yaml.bak saved)
```

### B) Bootstrap role workers

```bash
./scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
```

Writes `.orca/orchestration/handles.json`. Re-run after closed tabs / invalid handles. Duplicate tabs possible if old `role-*` tabs still open — close them first when clean slate is needed.

### C) Route + supervised dispatch

Use **supervised** lifecycle only when the user wants coordinate / supervise / wait / DAG / results:

1. Read `.orca/orchestration/roles.yaml` routing_table (and AGENTS.md).
2. Pick primary role (and secondary if dual path).
3. Dispatch:

```bash
./scripts/orca-dispatch-role.sh architect --spec "Plan only: <goal>. Follow AGENTS.md."
./scripts/orca-dispatch-role.sh executor  --spec "Implement approved plan: …"
./scripts/orca-dispatch-role.sh thrifty   --spec "Read-only map: …"
```

4. Wait with rolling windows (timeout ≠ failure):

```bash
orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

5. On rate/session limit:

```bash
./scripts/orca-fallback-on-limit.sh --from <role|term_*> --spec "Continue: <goal + partial>"
```

### D) Full handoff (no lifecycle)

If user says hand off / 넘겨줘 without supervise language: do **not** task-create/dispatch/check. Use `orca terminal send` or non-lifecycle worktree handoff only. See generic `orchestration` skill ownership rules.

## Routing cheat sheet

| User need | Role |
|-----------|------|
| Design, ambiguous scope, high-risk review | architect |
| Hard implement, debug, typecheck/build, close PR unit | executor |
| Small fix, map code, research, prototype | thrifty |
| Primary hit session/rate/quota limit | fallback |

Standard DAG: `architect(plan) → executor|thrifty(impl) → architect(review-only)`.
Cost ladder: `thrifty → executor → architect`.

## Spec hygiene

Scripts auto-prefix `[ROLE=<role> | <model>]`. Body should include:

- Goal (one sentence end state)
- Constraints (from AGENTS.md / product guardrails)
- Allowed file scope
- Done definition / verification commands

Edit ownership: one role edits a file set at a time; review-only architect does not bulk rewrite.

## Coordinator checklist

1. `orca status --json` ready
2. Scaffold present (`roles.yaml` + scripts) or run install
3. Handles valid or bootstrap
4. Route by roles.yaml
5. Dispatch --inject → check --wait
6. Limit → fallback script
7. Synthesize worker_done bodies; re-dispatch fixes if needed

## Do not

- Substitute generic subagents for Orca dispatch when user asked for Orca role orchestration
- Use fallback as default quality lane
- Retry a limited primary until its window resets
- Claim orchestration without `task-list` / `dispatch-show` proof after supervised work

## Related

- Generic Orca lifecycle: skill `orchestration`
- Project playbook after install: `.orca/orchestration/PLAYBOOK.md`
