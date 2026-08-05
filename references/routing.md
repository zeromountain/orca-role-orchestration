# Routing detail and DAG catalog

Read when a routing decision is non-obvious, or when composing a multi-step DAG.
The machine-readable source is `.orca/orchestration/roles.yaml` (`routing_table`,
`dags`) plus the user's `.orca/orchestration/project_hints.yaml` — read both
before routing; hints win for project-specific paths.

## Routing table

| Match | When | Primary | Secondary |
|-------|------|---------|-----------|
| architecture_or_plan | New feature design, ambiguous requirements, multi-package impact | architect | — |
| high_risk_review | auth, PII, security, migrations, privacy, high-stakes ship | architect | executor |
| hard_implementation | Approved plan, multi-file non-trivial code, tool-heavy debug | executor | thrifty |
| terminal_agent_loop | Shell-heavy repro, multi-step CLI workflow | executor | — |
| image_generation | New/edited raster image (see `image-generation.md`) | executor | — |
| small_ticket | Clear 1-3 file change, docs polish, rename | thrifty | — |
| codebase_map | Find where X lives (read-only) | thrifty | — |
| research_or_alternatives | External research, competitor/platform alternatives | thrifty | architect |
| prototype | Spike / demo / one-shot mock (code or UI, not raster images) | thrifty | architect |
| verification | typecheck, build, test, integrate | executor | — |
| dual_review | High stakes ship gate | architect | executor |

Cost ladder: `thrifty → executor → architect`. Start at the cheapest role that
can plausibly finish the work; escalate on design risk, not on difficulty alone.

## DAG catalog

**feature_plan_execute_review** — the standard shape.
`architect(plan) → executor(implement) → architect(review-only)`

- plan: file list, risks, verification commands. No bulk implementation.
- implement: only the approved plan, stay in the listed files, run verification.
- review: correctness / constraints / security. Do not edit beyond a critical one-liner.

**small_fix_fast** — `thrifty(fix)`. Smallest diff, lightest relevant verification.

**high_risk_change** — auth / PII / security / migration.
`architect(plan) → executor(implement) → architect(dual_review) → executor(verify)`

**explore_then_build** — unknown area.
`thrifty(map, read-only, file:line table) → architect(plan) → thrifty(implement)`

**research_then_integrate** — external research into the project.
`thrifty(research) → architect(critique) → executor(integrate)`

**image_generate** — see `image-generation.md`. `executor` only, after the clarity gate.

## Edit ownership

One role edits a given file set at a time. A review-only architect must not
rewrite executor/thrifty files unless it is re-dispatched to do so.

## Limit failover

On a rate/session/quota limit, do not hammer the limited primary. Create a NEW
task for `fallback` carrying the goal plus partial progress:

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from <role|term_*> --spec "Continue: …"
```

Detection patterns live only in that script (`LIMIT_RE`). Fallback is a
continuity lane, never the default quality lane — hand back to the primary once
its window resets.
