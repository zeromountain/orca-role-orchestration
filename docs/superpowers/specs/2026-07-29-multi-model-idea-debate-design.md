# Multi-model idea debate — design

Date: 2026-07-29
Status: approved by user; advisor verdict "수정 후 GO" — findings incorporated below

> **2026-07-30 revision (Task 3, label-native anonymization):** the original design below
> ("§2 Anonymization") described writing round output under a model's own name and then copying
> a redacted version elsewhere. That shipped with five confirmed authorship leaks — the anonymized
> copy differed from its named original by exactly one line, so a single `diff` deanonymized it;
> the label map itself lived inside the debate directory that every round-2 spec was told to read;
> round 3 pointed a debater at its own round-1 file by model-named path; the manifest recorded
> `{"debater": "claude", …}` inside the debate directory; and labels were assigned positionally
> from `--debaters` order, itself a public constant, so `A=claude` was derivable from source alone
> regardless of where the key file lived. §2 and §4 below are updated in place to describe what
> actually ships now, not the original (broken) design. See `task-3-report.md` for the fix.

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

### Anonymization (label-native — Task 3)

Round output is written under its label from the start: `round-1/A.md`, `round-2/B.md`,
`round-3/C.md`. There is no model-named original anywhere and no copy step — the earlier design
(write as `round-1/claude.md`, then copy a redacted version to `round-2/proposal-A.md`) is what
produced the one-line-diff leak above, structurally, regardless of what the copy's header said:
any two files that both exist and differ by exactly the author line are one `diff` away from
deanonymizing each other. Removing the named original removes the defect at its root.

**Label assignment is shuffled per debate**, not positional from `--debaters` order — the CSV
order is itself a public constant (`DEBATERS_DEFAULT` in `orca-debate-lib.sh`), so a positional
A=first-in-roster scheme is derivable from source alone no matter where the key file lives.
`debate_label_map_ensure` (in `orca-debate-lib.sh`) shuffles fresh on creation via Python's
`random`, and is the **only** function that ever creates or rewrites the map.

**Ownership is driver-only.** The label map lives at `$ORCH/debate-labels/<slug>.json` — outside
the debate directory entirely — and records `{"slug", "roster", "labels"}` (roster recorded so a
roster change on a re-run is detected and rebuilt, never silently reused — see §3.3). Only
`orca-debate.sh` (the driver) ever creates, rebuilds, or decides this file's lifecycle;
`orca-debate-round.sh` only ever reads it, via a required `--label-map <path>` flag the driver
passes down. The per-round manifest (`{"debater": "claude", "taskId": …, "status": …}` — real
short names, needed for driver-side debugging) moves the same way, to
`$ORCH/debate-manifests/<slug>/round-N.json`, passed via an optional `--manifest <path>` flag.
Neither file is ever named in a debater's dispatch spec.

Rationale for shuffling + external ownership: when a model sees "this came from Opus" — or can
derive it from a public roster-order constant — status deference collapses the debate into
agreement. Both proposals and critiques circulate under the same stable per-debate labels, so
"Proposal C" and "Critique C" are the same debater throughout one debate.

**Honest limit — this is not cryptographic.** The achievable guarantee is: nothing instructs a
debater to deanonymize, and no single `diff`, `glob`, or file read *inside the debate directory*
reveals authorship. Debaters run under the same permission-bypass flags as every other role (see
`role_launch_cmd`), so a debater that went off its instructions could still read
`dispatch-ledger.jsonl`, `handles.json`, `terminal-journal.jsonl`, or `orca terminal list` titles
— none of those live inside the debate directory and no spec ever points a debater at them, but
none are hidden from a process with full filesystem access either. `templates/roles.yaml`'s
`read_only` field is documented as prompt-enforced, not a sandboxing fact, for the same reason.
The transcript (`transcript.md`, written only after the debate concludes, never referenced by any
round spec) is the one deliberate exception: it re-attributes each round file back to its real
short name for the human reader, via a reverse lookup through the external label map.

### Context passing

Round specs pass **file paths, not inlined text**, and always point at the PREVIOUS round's own
directory (every file in it is already label-named — nothing to copy or redact): a critique
spec (round N=2) reads `round-1/*.md`; a converge spec (round N=3) reads `round-2/*.md` for the
critiques and its own `round-1/<own-label>.md` for its own earlier proposal — by label, never by
model-named path (the literal `round-1/<short>.md` path was the R3 leak above). This keeps the
injected preamble small and removes any need for character-count truncation of debate content.

### Round output schemas

Each debater writes markdown to an assigned path, named by its LABEL — never its model name (see
§2 above; the path and the required headings below are the literal, current output of
`debate_spec` in `scripts/orca-debate-lib.sh`, not an illustrative example). The schema is part of
the dispatch spec and is what prevents mutual agreement from being cheap — every round forces an
act of dissent.

**R1 → `round-1/<label>.md`**

```markdown
# R1 proposal

## Prior art
List 3-6 things that already exist in this space: what they do, how far they got, and where they
stopped. One line each, every line tagged with a source.

## Proposals
Give 2-3. For each:

### P1. <one-line name>
- Core hypothesis:
- Target user / JTBD:
- Why now:
- Differentiating axis: (what is actually different from the prior art above)
- Weakest link: (the strongest argument against your OWN proposal — required)
- Evidence: [출처: …]

## Directions I deliberately rejected
What you considered and dropped, and why. At least two.
```

**R2 → `round-2/<label>.md`**

```markdown
# R2 critique

## Verdict per proposal
One block per proposal EXCEPT your own:

### Proposal <label>
- Fatal flaw: (at least one; "none" alone is not accepted without justification)
- Unverified claims attacked: (target [출처: 미검증] claims first)
- What is worth keeping:
- Verdict: KILL | CONDITIONAL (condition: …) | SURVIVE

## Ranking
Rank every proposal you critiqued, strongest first. Ties are not allowed.

## Merged proposals
At most 2. For each:

### M1. <name> = <label>'s X + <label>'s Y
- Why the merge beats either alone:
- New risk the merge introduces:

## Retractions from my own R1
Anything in your own proposal you no longer defend, and why. "None" is allowed only if you say
what would have changed your mind.
```

**R3 → `round-3/<label>.md`**

```markdown
# R3 niche convergence

## Differentiating axes
2-3 axes. For each: why this axis separates a defensible niche from a crowded market.

## Niche candidates
1-2, ranked. For each:

### N1. <name>
- One-sentence definition:
- Who I am explicitly giving up:
- Why this is a niche: (structural reason incumbents cannot or will not do it)
- First validation experiment: (runnable in 1-2 weeks; success/failure stated as a number)
- Kill condition: (what fact would make you abandon this)
- Largest remaining uncertainty:

## Dissent
Candidates from the critiques that you do NOT support, and why. Must not be empty — if you
support everything, say what you would sacrifice first.
```

No header anywhere carries a model name or lens label — the persona/lens is what makes each
debater's *content* distinct, not a token in the required structure, and the anonymity guarantee
in §2 depends on that (a `# R1 proposal — <model> (<lens>)` header would itself be exactly the
kind of authorship leak §2 exists to close). Required-dissent fields — R1 "weakest link", R2
mandatory fatal flaw + forced ranking, R3 "dissent" — are the mechanism against a four-way
agreement spiral.

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
orca-debate-round.sh --dir <debate-dir> --round <N> --phase propose|critique|converge
                     --label-map <path> [--manifest <path>]
                     [--debaters a,b,c,d] [--timeout-ms N]
```

1. Build a per-debater spec: phase template + topic + assigned output path (this round's own
   directory, named by that debater's LABEL — `round-N/<label>.md`, looked up via
   `debate_label_of` against `--label-map`) + (critique/converge) the previous round's own
   directory to read.
2. Dispatch each debater via `orca-dispatch-role.sh <role> --spec … --persist`, parsing the
   `task_id=` line from its stdout. Reusing that script inherits `ensure_terminal` (recreate dead
   tabs, reseed persona) and the dispatch ledger. Immediately before dispatch, any pre-existing
   file at that debater's target path is removed — a stale file left by a previous, crashed run
   at the exact same path must never be mistaken for this run's output (deferred finding I1).
3. Poll `orca orchestration dispatch-show --task <id> --json` per task until `completed|failed`
   — the same non-consuming mechanism `orca-reap-task.sh` uses. **No inbox consumption**, so the
   round collector never races the reaper, another supervised task, or the coordinator's own
   `check --wait`.
4. Completion for a debater = `status=completed` **and** its output file exists and is non-empty.
5. Nothing to prepare for the next round: output was already written directly under its label
   name in step 1, so there is no copy or redaction step (Task 3 removed it — see §2). The
   per-round manifest, if `--manifest` was given, is written there directly (real short names —
   driver-only, outside the debate directory).

`--label-map` is required and must already exist for a real (non-dry-run) round — this script
never creates or owns it (see §2's "ownership is driver-only"); a missing file is a usage error
(exit 1), not a quorum failure (exit 2). `--dry-run` tolerates a missing/absent map (falls back to
a "?" placeholder for the own-label preview text) since nothing is actually dispatched.

**Naming.** A debater's short name is its role key minus the `debater_` prefix — `claude`,
`codex`, `grok`, `gemini`. Short names are what `--debaters` accepts, what the label map's
`roster`/`labels` keys are indexed by, and what the manifest records; role keys are what the
dispatch and handles layers use. Output files are named after the debater's LABEL (§2), never its
short name — the one exception is the transcript, which re-attributes by short name for the human
reader.

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
- **Refuses to start if another slug's debate is currently live** (Task 3): before writing its own
  lock, the driver enumerates every OTHER file under `$ORCH/debate-locks/*.json` and refuses (exit
  1, naming the other slug and its owner pid) if any of them is fresh (`lock_is_fresh`) — because
  `ensure_terminal` reuses each role's terminal globally, two concurrent debates under different
  slugs would otherwise dispatch into the SAME four agent sessions (observed live: a second
  driver's cleanup closed the first driver's tabs mid-round). A stale other-slug lock does not
  block. `--slug` is sanitized (rejects `/`, `..`, empty) before it is used to build a path.
  The scan-then-register sequence itself is wrapped in a global, mkdir-based startup mutex
  (`debate_startup_mutex_acquire`/`_release`, `orca-debate-lib.sh`) — a plain scan is a TOCTOU
  race on its own, since this driver's own lock does not exist until AFTER the scan passes, so
  two different-slug drivers started close together could each see "no one else" and both
  proceed. mkdir's atomicity gives mutual exclusion over the whole scan-then-register step
  without `flock` (unavailable on bash 3.2/macOS); the mutex is released the instant this
  driver's own lock is written, not held for the debate's lifetime. A held claim is reclaimed,
  once old enough (2s — several orders of magnitude above the real gap between the mutex's own
  `mkdir` and its pid-file write) to rule out stealing from a peer still mid-registration, in
  either of two cases: its recorded owner pid is confirmed dead, or no pid was ever recorded at
  all (the crash-before-writing-it case — found by direct reproduction: requiring a pid to exist
  before even checking staleness left a pid-less claim unreclaimable at ANY age, a silent,
  total, permanent block on every future debate start). Age is what tells a crash apart from a
  peer legitimately mid-`mkdir`, in both cases — never "no pid recorded" alone.
- Creates the debate directory, writes `topic.md`. For a real (non-dry-run) run of a given slug,
  clears any previous run's `round-*/`, `transcript.md`, and manifests for that slug first — there
  is no partial-resume feature (the loop below always restarts at round 1), so a prior run's
  leftovers must never be mistaken for this run's (deferred finding I1). Then
  creates/rebuilds the label map (`debate_label_map_ensure`) before round 1. `--dry-run` never
  writes the real label map — it uses a throwaway `mktemp` path instead, so a partial-roster
  preview can never poison a later real run.
- Runs R1 → R2 → R3 through the round script, passing `--label-map`/`--manifest` down each time.
  Distinguishes the round script's exit 2 (quorum genuinely failed) from exit 1 (a usage/internal
  error in the round script itself) — treating them the same would misreport a usage bug as a
  debate that failed to converge.
- Concatenates `transcript.md`, re-attributing each round file back to its real short name via the
  external label map (falling back to the raw label if the map is unavailable).
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
`lifecycle.debate` in `roles.yaml` rather than left as an undocumented violation. Two *debates*
running at once is a different, cross-slug concurrency problem — see the driver-refusal bullet
above.

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
  round-1/{A,B,C,D}.md                     # label-named from the start — no model-named file
  round-2/{A,B,C,D}.md
  round-3/{A,B,C,D}.md
  transcript.md                            # the ONE place real short names appear (re-attributed)
docs/ideas/YYYY-MM-DD-<slug>.md            # decision document (committed)

.orca/orchestration/debate-labels/<slug>.json          # {"slug","roster","labels"} — driver-only
.orca/orchestration/debate-manifests/<slug>/round-N.json  # real names, task id, status, flags — driver-only
```

The label map and per-round manifests are deliberately **outside** `debates/<slug>/` — nothing a
debater's dispatch spec ever points at, and nothing that would survive a `glob`/`diff`/read of the
debate directory tree. Only the driver (`orca-debate.sh`/`orca-debate-round.sh`) ever reads them;
a debater running off its instructions could still find them (see §2's honest limit), but no
instruction ever tells it to look, and neither lives where "read every file matching
`round-N/*.md`" would ever reach.

The installer appends `.orca/orchestration/debates/`, `debate-labels/`, and `debate-manifests/` to
the project `.gitignore` alongside the existing `handles.json` entry.

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
