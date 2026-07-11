# Design: Orca Role Persona Enhancement

Date: 2026-07-11
Status: Approved (brainstorming)
Topic: Give each Orca role model a clear, specific, injectable persona so workers perform better during real task execution.

## Problem

The four Orca roles (`architect`, `executor`, `thrifty`, `fallback`) each already have a
`persona:` field in `templates/roles.yaml`, but:

1. **The rich persona never reaches the worker.** `scripts/orca-bootstrap-roles.sh` has its own
   hardcoded `seed()` bodies (one line per role, lines 119-126). It does **not** read the
   `roles.yaml` personas. So the actual instruction a worker terminal receives is a single terse
   sentence, while the more detailed persona in `roles.yaml` is documentation only.
2. **`scripts/orca-dispatch-role.sh` injects no persona** — it only prepends `[ROLE=<role> | <model>]`.
3. **Duplication / drift risk.** Two sources of "what this role is" (roles.yaml + bootstrap seed) that
   are not kept in sync.

Net effect: personas are under-specified *and* under-delivered, which caps worker performance.

## Goal

- Rewrite each role's persona as a rich **operating profile + light character** (professional archetype).
- Make the persona **actually reach the worker**: bootstrap injects the full persona; dispatch injects a
  compact one-line reminder each task.
- Keep a **single source of truth** with **zero new dependencies** (no YAML parser required).

## Non-goals

- No change to the fixed four-role model lineup or launch commands.
- No change to routing tables, DAGs, lifecycle rules, or the fallback failover mechanism.
- No fantasy names / heavy roleplay — professional archetypes only (chosen to avoid degrading coding).

## Design decisions (from brainstorming)

| Decision | Choice |
|----------|--------|
| Persona style | Operating profile centered + light character |
| Storage/injection structure | **A** — separate `personas/<role>.md` files, read & injected by bootstrap |
| Character level | Professional archetypes (`The Strategist`, `The Closer`, `The Scout`, `The Relief Pitcher`, `The Conductor`) |
| Dispatch reminder | **Include** — extract a one-line `STANCE` marker from the persona file per dispatch |

## Architecture

Single source of truth = `personas/<role>.md`. Two consumers, both dependency-free (plain file read + `grep`/`sed`):

```
install-to-project.sh  → copies templates/personas/*.md  → .orca/orchestration/personas/
orca-bootstrap-roles.sh→ reads .orca/orchestration/personas/<role>.md (full) → seeds worker terminal
orca-dispatch-role.sh  → greps the STANCE line from personas/<role>.md → compact reminder before spec
```

- `templates/roles.yaml` stops embedding full persona text. Each role keeps:
  - `persona_file: personas/<role>.md` (path relative to `.orca/orchestration/`)
  - `persona_summary:` — a single human-readable line (documentation; not the injection source)
- Fallbacks: if a persona file is missing, bootstrap falls back to the role's `persona_summary`-style
  one-liner it already hardcodes today, and dispatch simply skips the reminder. No hard failure.

### Persona file format

Every persona file follows one skeleton (content differs per role):

```markdown
# <ROLE> — "<Archetype>"  (<Model>)

<!-- STANCE: <one compact line injected at dispatch time> -->

**Who you are.** Archetype + 2-3 personality traits + core stance (the light character).
**Mission.** One sentence: the end-state this role owns.
**Play to these strengths.** Model-specific strengths to exploit (bullets).
**Guard against these failure modes.** This model's known anti-patterns + the counter-move (bullets).
**How you decide (heuristics).** Act-vs-escalate rules, cost/risk thresholds.
**Output contract.** The exact expected shape of this role's deliverable.
**Collaboration protocol.** Handoff / escalation / worker_done rules; who you defer to.
**Definition of done.** The quality bar before claiming complete.
**Never.** Hard do-not list.
```

The `<!-- STANCE: ... -->` HTML comment on line 2 is the machine-readable hook. Dispatch extracts exactly
this line (via `grep`/`sed`) so the compact reminder and the full persona never drift.

### The five archetypes

| Role | Archetype | Model | Core stance |
|------|-----------|-------|-------------|
| architect | **The Strategist** | Claude Opus 4.8 | Cool, skeptical, principled staff+ engineer & reviewer. Push back on weak plans with evidence. Delegate bulk implementation. Deliverables = plans/ADRs + Critical/Major/Minor reviews. |
| executor | **The Closer** | GPT-5.6 Sol | Terminal-native finisher. Execute the approved plan end-to-end, verify before declaring done, integrate. Resist over-engineering open-ended scope. |
| thrifty | **The Scout** | Grok 4.5 | Fast, wide, low-cost explorer. Small diffs, broad recon, cite source+date for external facts, escalate design risk early. |
| fallback | **The Relief Pitcher** | Gemini 3.5 Flash (Medium) | Calm, conservative continuity specialist. Enter only when a primary hits a limit; stabilize with smallest viable progress; hand back. Never re-architect. |
| coordinator | **The Conductor** | any | Decompose into a DAG, route by model strength, synthesize. Never bulk-implement. Reference-only (not a bootstrapped terminal). |

`coordinator.md` is documentation for the orchestrating agent; it is NOT injected by bootstrap (the
coordinator is the running agent, not a role worker terminal).

## File-by-file changes

1. **NEW `templates/personas/architect.md`, `executor.md`, `thrifty.md`, `fallback.md`, `coordinator.md`**
   - Each follows the skeleton above with role-specific content and a `STANCE` line.

2. **`templates/roles.yaml`** (edit)
   - For each of the 4 worker roles: replace the multi-line `persona: |` block with
     `persona_file: personas/<role>.md` + `persona_summary: <one line>`.
   - Add a top-of-file comment documenting the persona-file convention.
   - Leave `owns`, `route_keywords`, `routing_table`, `dags`, `limit_failover`, `lifecycle`,
     `project_hints` unchanged. Optionally add a `persona_file` for the `coordinator` role too.

3. **`scripts/orca-bootstrap-roles.sh`** (edit)
   - Add a helper to read `$OUT_DIR/personas/<role>.md`; strip the `# ...` H1 and the `<!-- STANCE -->`
     comment for cleanliness (or inject as-is minus the HTML comment).
   - `seed()` uses the file content as `$body`. If the file is absent, keep the current hardcoded
     one-liner as fallback (backward compatible).

4. **`scripts/install-to-project.sh`** (edit)
   - `mkdir -p "$ORCH/personas"` and copy each `templates/personas/*.md` via the existing
     `install_file` (so `{{PROJECT_NAME}}` substitution still works and `--force` is respected).

5. **`scripts/orca-dispatch-role.sh`** (edit)
   - After resolving `$MODEL`, read `.orca/orchestration/personas/<role>.md`, extract the STANCE line,
     and build:
     ```
     [ROLE=<role> | <model>]
     STANCE: <stance line>
     <spec>
     ```
   - If the persona file or STANCE line is missing, fall back to today's `[ROLE|model]\n<spec>` exactly.

6. **Docs** (edit)
   - `SKILL.md`: add `personas/` to the skill layout; note bootstrap injects the full persona and
     dispatch injects the STANCE reminder.
   - `templates/PLAYBOOK.md`: short "Personas" section describing where personas live and how they flow.
   - `templates/SCRIPTS.md`: note the `personas/` directory is installed and consumed by bootstrap/dispatch.

## Data / control flow

```
[install]  templates/personas/*.md ──copy──▶ .orca/orchestration/personas/*.md
[bootstrap] personas/<role>.md ──full text──▶ orca terminal send (seed)  ▶ worker holds persona
[dispatch]  personas/<role>.md ──STANCE line──▶ prepended to task spec    ▶ per-task reminder
[fallback]  unchanged; failover spec still routes to ROLE=fallback (Relief Pitcher persona already seeded)
```

## Error handling / backward compatibility

- Missing persona file → bootstrap uses existing hardcoded one-liner; dispatch omits STANCE line.
  Nothing breaks for repos installed before this change.
- No new runtime dependency: all extraction is `grep`/`sed`/plain read. YAML is never parsed by scripts.
- `--force` semantics on install unchanged; persona files copied through the same `install_file` path.

## Testing / verification

- `bash -n` on all three modified scripts (syntax).
- Dry-run install into a scratch dir: confirm `.orca/orchestration/personas/*.md` created and
  `roles.yaml` contains `persona_file`.
- Extract-STANCE unit check: `grep`/`sed` on each persona file returns exactly one non-empty stance line.
- Skeleton lint: each persona file contains all required section headers and a `STANCE` marker.
- Manual read-through of each persona for the operating-profile sections + archetype voice.

## Open questions

None — all resolved during brainstorming.
