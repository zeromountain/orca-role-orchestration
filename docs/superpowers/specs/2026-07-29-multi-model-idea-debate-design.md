# Multi-model idea debate — design

Date: 2026-07-29
Status: approved by user; advisor verdict "수정 후 GO" — findings incorporated below

## Goal

Add an orchestration mode where Claude, Codex (GPT), Grok, and Gemini propose ideas to each
other, attack each other's proposals, and converge on a **niche** (deliberately narrow,
differentiated) direction — driven by one command, with a committed decision document as
the output.

## Non-goals

- Replacing the existing development roles (`architect`/`executor`/`thrifty`/`ui`/`reviewer`/`fallback`).
  Debate roles are additive and never implement code.
- Automatic idea implementation. The debate ends at a decision document; building it is a
  separate, existing flow.
- Dynamic round counts. Three rounds, fixed. Re-running with a reframed topic is the escape
  hatch when a debate collapses.
- Auto-retry of a debater whose output fails the schema lint (see §3.4 — deferred, not silently
  dropped).

## 1. Roles

Four new roles, one per provider, each with a distinct **lens** so R1 produces genuinely
different proposals rather than four rewordings of the same idea. Lenses are matched to the
model strengths already documented in `references/model-roles.md`.

| role key | tab title | agent | model | CLI | lens |
|---|---|---|---|---|---|
| `debater_claude` | `debate-opus` | claude | `claude-opus-5` | `claude` | **Principle & risk** — long-horizon coherence, failure modes, regulatory/ethical exposure |
| `debater_codex` | `debate-sol` | codex | `gpt-5.6-sol` | `codex` | **Feasibility** — build cost, technical risk, shortest credible path to a shippable slice |
| `debater_grok` | `debate-grok` | grok | `grok-4.5` | `grok` | **Contrarian & market** — angles nobody is taking, volume of alternatives, prior art sweep |
| `debater_gemini` | `debate-agy` | antigravity | `Gemini 3.6 Flash (Medium)` | `agy` | **Demand & user** — JTBD, concrete usage scenarios, evidence that anyone wants this |

Launch commands mirror the existing roles' flags (see `role_launch_cmd` in
`scripts/orca-roles-lib.sh`). Debaters are **not** created by `orca-bootstrap-roles.sh`; the
existing `ensure_terminal` path creates them on demand at first dispatch.

### Write boundary

Debaters run under permission-bypass flags like every other role. Their persona and every
dispatch spec must state the boundary explicitly:

> Your only writable path is the output file assigned in your spec, under
> `.orca/orchestration/debates/<slug>/`. Never create or edit any other file. Never run
> `git commit`, `git add`, or any command that changes repository state. You are a discussant,
> not an implementer.

`debater_gemini` shares the `agy` CLI and Gemini quota with `ui` and `fallback`. On a limit,
drop to three debaters rather than substituting another model — swapping a model destroys the
lens diversity that makes the debate worth running.

## 2. Protocol

Three rounds, four debaters in parallel per round.

```
R1 propose   research-first, independent (debaters cannot see each other)
R2 critique  each debater reads the other three proposals under anonymous labels
R3 converge  narrow to 1-2 niche candidates with kill conditions
```

### Anonymization

A debater's own output files are named after it (`round-1/claude.md`), so they can never be
handed to another debater directly. Before each round that consumes prior work, the round script
writes **anonymized copies** under stable labels:

- after R1 → `round-2/proposal-{A,B,C,D}.md`
- after R2 → `round-3/critique-{A,B,C,D}.md`

The label→model mapping is assigned once, recorded in `round-2/label-map.json`, and reused for
both sets, so "Proposal C" and "Critique C" are the same debater throughout. Model names never
appear inside a copy. Each spec states which label is that debater's own.

Rationale: when a model sees "this came from Opus", status deference collapses the debate into
agreement — and that applies to critiques as much as to proposals. Anonymizing both is one extra
call to the same helper.

### Context passing

Round specs pass **file paths, not inlined text**. R2 specs point at `round-2/proposal-*.md`;
R3 specs point at `round-3/critique-*.md`. This keeps the injected preamble small and removes any
need for character-count truncation of debate content.

### Round output schemas

Each debater writes markdown to an assigned path. The schema is part of the dispatch spec and
is what prevents mutual agreement from being cheap — every round forces an act of dissent.

**R1 → `round-1/<model>.md`**

```markdown
# R1 proposal — <model> (<lens>)

## Prior art (3-6 items)
- <what exists, how far it got> [출처: URL | 제품명 | 미검증]

## Proposals (2-3)
### P1. <one-line name>
- Core hypothesis:
- Target user / JTBD:
- Why now:
- Differentiating axis: (what is actually different from the prior art above)
- Weakest link: (the strongest argument against my own proposal — REQUIRED)
- Evidence: [출처: …]

## Directions I deliberately rejected, and why
```

**R2 → `round-2/<model>.md`**

```markdown
# R2 critique — <model>

## Verdict per proposal (all except my own)
### Proposal <label>
- Fatal flaw: (at least one required; "none" is not an accepted answer without justification)
- Unverified claims attacked: (target [출처: 미검증] claims first)
- What is worth keeping:
- Verdict: KILL | CONDITIONAL (condition: …) | SURVIVE

## Ranking
1. … 2. … 3. …   (all critiqued proposals, strongest first — ties not allowed)

## Merged proposals (max 2)
### M1. <name> = <label>'s X + <label>'s Y
- Why the merge beats either alone:
- New risk the merge introduces:

## Retractions from my own R1 (if any)
```

**R3 → `round-3/<model>.md`**

```markdown
# R3 niche convergence — <model>

## Differentiating axes (2-3)
- <axis>: why this axis separates a niche from a crowded market

## Niche candidates (1-2, ranked)
### N1. <name>
- One-sentence definition:
- Who I am explicitly giving up:
- Why this is a niche: (structural reason incumbents cannot or will not do it)
- First validation experiment: (runnable in 1-2 weeks, success/failure stated as a number)
- Kill condition: (what fact would make me abandon this)
- Largest remaining uncertainty:

## Dissent (candidates I do NOT support, and why)
```

Required-dissent fields — R1 "weakest link", R2 mandatory fatal flaw + forced ranking, R3
"dissent" — are the mechanism against a four-way agreement spiral.

### Research requirement

Every R1 spec requires prior-art research before proposing, and every factual claim carries a
`[출처: URL | 제품명 | 미검증]` tag. R2 specs instruct debaters to attack `미검증` claims first.
A debater without working web access tags its claims `미검증` rather than inventing a source.

## 3. Scripts

### 3.1 `orca-dispatch-role.sh --persist` (new flag on an existing script)

The current script **unconditionally** injects an AUTO-CLOSE block (`orca-dispatch-role.sh:106-112`)
telling the worker to close its own tab right after `worker_done`, and `seed()`
(`orca-roles-lib.sh:104-108`) plants the same instruction at terminal creation. `--no-reap` only
disables the background reaper, so it is **not sufficient** to keep a tab alive between rounds.

`--persist` therefore:

- implies `--no-reap`,
- replaces the AUTO-CLOSE block with a STAY-OPEN block ("send `worker_done`, then remain idle and
  wait for the next dispatch; do not close this terminal"), and
- pairs with a role-aware `seed()` that omits the self-close paragraph for `debater_*` roles.

Closing becomes the driver's responsibility (§3.3).

### 3.2 `scripts/orca-debate-round.sh` (primitive — one round)

```
orca-debate-round.sh --slug <s> --round <N> --phase propose|critique|converge
                     --dir <debate-dir> [--debaters a,b,c,d] [--timeout-ms N]
```

1. Build a per-debater spec: phase template + topic + assigned output path + (R2/R3) the paths
   to read.
2. Dispatch each debater via `orca-dispatch-role.sh <role> --spec … --persist`, parsing the
   `task_id=` line from its stdout. Reusing that script inherits `ensure_terminal` (recreate dead
   tabs, reseed persona) and the dispatch ledger.
3. Poll `orca orchestration dispatch-show --task <id> --json` per task until `completed|failed`
   — the same non-consuming mechanism `orca-reap-task.sh` uses. **No inbox consumption**, so the
   round collector never races the reaper, another supervised task, or the coordinator's own
   `check --wait`.
4. Completion for a debater = `status=completed` **and** its output file exists and is non-empty.
5. Write the anonymized copies for the next round (`proposal-*.md` after R1, `critique-*.md`
   after R2), creating `label-map.json` on the first call and reusing it afterwards.

**Naming.** A debater's short name is its role key minus the `debater_` prefix — `claude`,
`codex`, `grok`, `gemini`. Short names are what `--debaters` accepts and what output files are
named after; role keys are what the dispatch and handles layers use.

**Why file-based output, not message bodies.** `worker_done` payloads are conventionally short
summaries (`orca-wait-done.sh` reads only `subject` and `payload.taskId`), and four models
reliably packing a multi-thousand-word argument into a message payload is not a bet worth making.
Debaters write to a deterministic assigned path and pass it on `worker_done --report-path`;
`worker_done` is used purely as a completion signal, and the script reads the file from disk.

### 3.3 `scripts/orca-debate.sh` (driver)

```
orca-debate.sh --topic "…" | --topic-file <f>
               [--slug <s>] [--rounds 3] [--debaters a,b,c,d]
               [--judge <role>] [--timeout-ms N] [--keep-tabs]
```

- **Preflight**: `command -v` each selected debater's CLI (`claude`/`codex`/`grok`/`agy`) and
  `orca status --json` reachability. Missing CLIs are dropped from the roster with a warning; if
  fewer than 3 remain, abort before creating anything.
- Creates the debate directory, writes `topic.md`, runs R1 → R2 → R3 through the round script.
- Concatenates `transcript.md`.
- `--judge <role>` dispatches that role to write the decision document; otherwise prints the
  coordinator instruction to write it.
- **Closes all debater tabs on exit** via `trap … EXIT INT TERM`, reusing `orca-close-role.sh`.
  `--keep-tabs` opts out for debugging.

Tabs persist across rounds so each debater remembers its own earlier statements, and CLI cold
starts drop from 12 to 4.

**Per-round timeouts.** R1 carries a research obligation and gets a longer default (30 min) than
R2/R3 (15 min each). `--timeout-ms` overrides all rounds.

**Concurrency.** Four debaters run simultaneously, exceeding `lifecycle.max_concurrent: 2`. That
value is documentation only — no script enforces it (verified by grep; the sole occurrence is
`templates/roles.yaml:479`) — and it exists to prevent two roles from editing the same files.
Debaters never edit project files, so the debate path is exempt. Recorded explicitly as
`lifecycle.debate` in `roles.yaml` rather than left as an undocumented violation.

### 3.4 Schema lint

After collecting a round, the script greps each output for the round's required headings. A
missing heading marks that file `LINT-FAIL` in the round manifest and prints a warning; the
content is still kept and still enters the transcript. Automatic re-request of a
non-conforming debater is **deferred** — it needs a second dispatch cycle per debater and is not
worth the complexity until we see how often real outputs drift.

### 3.5 Failure handling

| Failure | Behavior |
|---|---|
| One debater times out, fails, or produces no file | Warn, record `forfeit` in the round manifest, continue |
| **Quorum**: 3+ debaters produced usable output | Continue to the next round |
| **Quorum**: 2 or fewer | Abort the debate; transcript keeps what completed |
| Output fails schema lint | Keep content, mark `LINT-FAIL`, continue (§3.4) |
| `agy` quota exhausted (shared with `ui`/`fallback`) | Warn and instruct re-running with `--debaters` minus `debater_gemini`; no automatic model substitution |

## 4. Output layout

```
.orca/orchestration/debates/<slug>/        # gitignored (local runtime state)
  topic.md
  round-1/{claude,codex,grok,gemini}.md  manifest.json
  round-2/proposal-{A,B,C,D}.md  label-map.json  {claude,…}.md  manifest.json
  round-3/critique-{A,B,C,D}.md  {claude,…}.md  manifest.json
  transcript.md
docs/ideas/YYYY-MM-DD-<slug>.md            # decision document (committed)
```

`manifest.json` per round records, for each debater: task id, status, forfeit/lint flags.

The installer appends `.orca/orchestration/debates/` to the project `.gitignore` alongside the
existing `handles.json` entry.

### Decision document contract

Whoever writes `docs/ideas/…` (coordinator by default, or `--judge <role>`) must produce three
sections, so a failure to converge is recorded rather than papered over:

- **Decision** — the chosen niche, its kill condition, and the first validation experiment.
- **Runner-up** — the strongest rejected candidate and why it lost.
- **Dissent** — positions from R3 that the decision does not resolve, attributed by model.

## 5. Configuration and documentation changes

- `templates/roles.yaml` — `roles.debater_*` (4), one `routing_table` entry `idea_debate`,
  `lifecycle.debate` recording the 4-wide read-only exemption, and a pointer to
  `orca-debate.sh`. Round prompt templates are **not** duplicated here: the script is their
  single source, matching the existing precedent that launch commands live in
  `orca-bootstrap-roles.sh` rather than `roles.yaml`.
- `templates/personas/debater_{claude,codex,grok,gemini}.md` — flat filenames so the installer's
  `personas/*.md` glob picks them up. Must satisfy `check-personas.sh`: an H1, a non-empty
  `<!-- STANCE: … -->`, and all nine skeleton sections.
- `SKILL.md` — new mode "Idea debate", debate rows in the role and routing tables, and
  frontmatter description keywords (`아이디어 토론`, `브레인스토밍`, `아이디어 구체화`, `debate`,
  `multi-model debate`, `니치`).
- `commands/debate.md` (Claude Code) and `prompts/orca-debate.md` (Codex).
- `templates/SCRIPTS.md`, `templates/PLAYBOOK.md`, `README.md`, `references/model-roles.md`.

## 6. Existing defects fixed in the same change

All are in files this work already touches; leaving them would ship a scaffold whose declared
roles cannot be dispatched or closed.

1. `scripts/orca-dispatch-role.sh:68` — role whitelist is still `architect|executor|thrifty|fallback`,
   so the already-shipped `ui` and `reviewer` roles cannot be dispatched. Add them plus `debater_*`.
2. `scripts/orca-close-role.sh:33-34` — same whitelist gap on the close path.
3. `scripts/check-personas.sh:8` — `ROLES` omits `ui` and `reviewer`, so their personas are never
   linted. Add them plus the four debaters.
4. `scripts/orca-bootstrap-roles.sh:88-93` — writes `handles.json` from its own hardcoded metadata
   (`claude-opus-4-8`, `Gemini 3.5 Flash (Medium)`) instead of `handles_set`, contradicting
   `role_meta` in `orca-roles-lib.sh` (`claude-opus-5`, `Gemini 3.6 Flash (Medium)`). Also stale in
   the header comment (lines 2-3) and the `seed` calls (lines 71-74). Route through the library so
   there is one source of role metadata.
5. `scripts/install-to-project.sh:269,277` — explicit script lists must include the two new scripts.
6. `scripts/install-to-project.sh:348` and `templates/PLAYBOOK.md` — role tables still say four
   roles, Opus 4.8, Gemini 3.5; they write stale information into user projects. The existing
   "skip if marker present" behavior for `AGENTS.md` stays as-is — no retroactive migration of
   already-installed projects.

## 7. Verification

- `scripts/check-personas.sh` passes with the extended role list.
- `bash -n` on both new scripts and every modified script.
- `tests/install.sh` passes; a fresh `install-to-project.sh` into a scratch directory copies both
  new scripts, all four new personas, and adds the `debates/` gitignore line.
- `python3 -c 'import yaml; yaml.safe_load(open("templates/roles.yaml"))'` parses.
- `handles.json` written by bootstrap matches `role_meta` for every role (regression test for
  defect 4).
- End-to-end smoke: one real `orca-debate.sh --rounds 1` run in this repo, confirming four tabs
  launch, four `round-1` files land, tabs stay open between rounds, and the trap closes them on exit.

## 8. Open questions

None blocking. The two previously-unknown mechanisms are resolved:

- **Collecting worker output** — `worker_done --report-path` plus deterministic output paths and
  `dispatch-show` polling, verified against the installed `orca` CLI (v1.4.155).
- **Keeping tabs alive between rounds** — requires the new `--persist` flag; `--no-reap` alone is
  defeated by the injected AUTO-CLOSE block and the seeded self-close instruction.
