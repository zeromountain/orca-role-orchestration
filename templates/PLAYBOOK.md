# Orca multi-model orchestration playbook

SSOT: `.orca/orchestration/roles.yaml`
Scripts: [`SCRIPTS.md`](./SCRIPTS.md)

| Role | Model | CLI | Own |
|------|-------|-----|-----|
| **architect** | Claude Opus 4.8 | `claude` | Design, judgment, high-risk review |
| **executor** | GPT-5.6 Sol | `codex` | Hard implement, terminal loops, verify, close work |
| **thrifty** | Grok 4.5 | `grok` | Small tickets, explore, research, prototypes |
| **fallback** | Gemini 3.5 Flash (Medium) | `agy` | **Rate/session limit only** |

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
orca status --json   # runtime.reachable true
# Settings → Experimental → Agent orchestration ON
which claude codex grok agy
```

Same-checkout work: `orca terminal create --worktree active` (do not invent worktrees).

## Bootstrap

```bash
.orca/orchestration/scripts/orca-bootstrap-roles.sh
# or
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree path:$(pwd)
```

Tabs: `role-opus-architect` · `role-sol-executor` · `role-grok-thrifty` · `role-agy-fallback`
Handles: `.orca/orchestration/handles.json` (gitignore).

## Dispatch (supervised)

Only when user asks to supervise / coordinate / wait / DAG:

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh architect --spec "Plan only: …"
.orca/orchestration/scripts/orca-dispatch-role.sh executor  --spec "Implement approved plan: …"
.orca/orchestration/scripts/orca-dispatch-role.sh thrifty   --spec "Read-only map: …"

orca orchestration check --wait \
  --types worker_done,escalation,decision_gate \
  --timeout-ms 900000 --json
```

Timeout / `count:0` = checkpoint, not failure if terminal still alive.

## Limit failover

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --check-handle term_…
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from architect --spec "Continue: …"
```

## Routing cheat sheet

| Request | Primary | Secondary |
|---------|---------|-----------|
| Design / ambiguous | architect | — |
| High-risk (auth/PII/security) | architect → executor → architect review | |
| Hard implement / debug | executor | thrifty explore |
| Small fix / rename / polish | thrifty | — |
| Map code (read-only) | thrifty | — |
| Research / alternatives | thrifty | architect critique → executor integrate |
| Prototype | thrifty | architect before promote |
| typecheck / build / test | executor | — |

## Patterns

```text
Plan → Execute → Review:  architect → executor|thrifty → architect(review-only)
Cost ladder:              thrifty → executor → architect
Limit:                    any primary → fallback (agy)
Research:                 thrifty → architect → executor
```

## Spec prefix

Scripts auto-prefix: `[ROLE=<role> | <model>]`

Always include project constraints from AGENTS.md / CLAUDE.md in the body.

## Handoff vs supervised

| Phrase | Mode |
|--------|------|
| hand off / 넘겨줘 | full handoff — `terminal send` only |
| supervise / 조율 / DAG / 완료 대기 | supervised — task-create + dispatch --inject + check --wait |
