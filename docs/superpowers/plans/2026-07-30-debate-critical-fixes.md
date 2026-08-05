# Debate Critical Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four Critical findings that blocked `feat/multi-model-idea-debate` from merging, then prove the feature works with one complete live round.

**Architecture:** Three of the four fixes are hardening of existing code (terminal lifecycle, message filtering, tab cleanup). The fourth replaces the anonymization layer's file naming so anonymity is a property of the layout rather than a promise in a prompt.

**Tech Stack:** Bash 3.2, Python 3 heredocs, `orca` CLI v1.4.155.

**Predecessor:** `docs/superpowers/plans/2026-07-29-multi-model-idea-debate.md` built the feature; its final whole-branch review returned "do not merge" with the four findings below.

## Why this plan contains no shell code

The predecessor plan wrote literal shell into every task. Fourteen defects were found during its execution and **thirteen were bugs in that plan's own code**, all shell semantics under `set -euo pipefail`: `pipefail` taking a pipeline's status from the failing command instead of `grep`, `source` being a special builtin that `|| true` cannot rescue, a signal handler that let execution resume, a stderr redirect that discarded the stream under test, a file-wide grep that passed on a partial rollback. The implementation code that subagents wrote was consistently sound.

So this plan specifies **intent, data contracts, and behavioral acceptance criteria**. Implementers write the shell. Where a contract must be exact — a JSON schema, an exit-code meaning, a file layout — it is stated exactly. Where control flow is involved, it is not.

## Global Constraints

- **Bash 3.2 compatible** (macOS default). No `declare -A`, no `mapfile`, no `${var,,}`.
- `set -euo pipefail` in executable scripts. Sourced libraries (`*-lib.sh`) must not set shell options.
- **Dual-copy discipline.** Every script exists twice: `scripts/<name>.sh` (source, edited) and `.orca/orchestration/scripts/<name>.sh` (runtime, executed). The driver, the docs, and every live run use the runtime copy. **A task is not done until `scripts/install-to-project.sh --project-root "$(pwd)"` has been re-run and every touched script is byte-identical between the two locations.** Verify with `cmp`, not by eye. Fixing only the source copy and then running live means testing stale code — the exact defect class that produced thirteen of the predecessor's fourteen findings.
- Model strings live only in `scripts/orca-roles-lib.sh`.
- No new runtime dependencies — Bash and Python 3 only.
- Debater short names are `claude`, `codex`, `grok`, `gemini`; role keys `debater_<short>`.
- Every task extends `tests/debate.sh` or `tests/install.sh`, both of which must stay runtime-free. Existing seams `ORCA_DEBATE_DISPATCH` and `ORCA_DEBATE_STATUS_STUB` are available.
- **Acceptance criteria in this plan are behavioral, not textual.** "grep finds the string" is not evidence a fix works. Each task states what must be observably true.

---

### Task 1: Terminal lifecycle — record before you can lose it

**Files:** `scripts/orca-roles-lib.sh`; tests in `tests/debate.sh`

**The defect.** `create_role` spawns a permission-bypassed agent session and *then* parses the handle out of the response. When that parse fails it exits non-zero; `ensure_terminal`'s bare assignment inherits the status and, under `set -euo pipefail`, the caller dies on that line. The terminal exists and nothing recorded it, so the cleanup trap — which iterates `handles.json` — cannot close it. This was observed live: the orphan was a Claude Code session sitting at a fresh welcome screen, bypass permissions on, never seeded.

Three more leaks share that window:
- `wait_idle` returns success whether or not the terminal ever became idle.
- `seed` discards `orca terminal send`'s result and never checks that the send landed anywhere. A debater seed was observed arriving in the coordinator's own session.
- `terminal_is_live` conflates "not live" with "could not determine". One failed `orca terminal list` reads as dead, and `ensure_terminal` then creates a second terminal for a role whose first is still running.

**What must become true**

1. A terminal's identity reaches durable storage in the same step that creates it. Whatever `orca terminal create` returns is written to disk before anything parses it, so a parse failure still leaves a record.
2. `handles_set` records the handle **before** `wait_idle` and `seed` run. A seeding failure must leave a closable terminal.
3. `terminal_is_live` distinguishes three outcomes, and `ensure_terminal` creates a replacement only on a definite "dead" — never on "could not determine".
4. `seed` verifies its send: the target must look like a handle (`term_*`), the send's result must indicate success, and the seed's arrival must be confirmed by reading the terminal back. Any failure is loud, not swallowed.

**Data contract — terminal journal**

Path: `$ORCH/terminal-journal.jsonl`, one JSON object per line, append-only:

| field | meaning |
|---|---|
| `role` | role key, or `null` if unknown at create time |
| `title` | the title passed to `orca terminal create` |
| `raw` | the create response verbatim, before any parsing |
| `handle` | parsed handle, or `null` if parsing failed |
| `createdAt` | ISO-8601 UTC |

`null` handle with a non-null `raw` is the signal an orphan sweep looks for. This file is local runtime state: gitignore it alongside `handles.json`.

**`terminal_is_live` contract:** exit 0 = definitely live, 1 = definitely not live, 2 = could not determine. Callers must treat 2 as "leave it alone".

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** With a stubbed `orca` whose `terminal create` returns a response containing no handle, `ensure_terminal` leaves a journal line with non-null `raw` and null `handle`. Prove the pre-fix code leaves nothing.
- [ ] **Step 2:** With a stubbed `orca` whose `terminal send` fails, the role's handle is still present in `handles.json` afterward, and the failure is reported on stderr rather than swallowed.
- [ ] **Step 3:** With a stubbed `orca` whose `terminal list` exits non-zero, `ensure_terminal` does **not** create a second terminal for a role that already has a handle. Prove the pre-fix code does.
- [ ] **Step 4:** `seed` refuses a target that is not `term_*`-shaped, with a distinct message.
- [ ] **Step 5:** `./tests/debate.sh`, `./tests/install.sh`, `./scripts/check-personas.sh` pass; `bash -n` clean.
- [ ] **Step 6:** Re-run the installer; `cmp` every touched script against its runtime copy.
- [ ] **Step 7:** Commit.

**Note for the implementer:** the six existing roles use this same code path. A regression here breaks `architect`/`executor`/`thrifty`/`ui`/`reviewer`/`fallback` dispatch, not just the debate. Treat the existing seed text for non-debater roles as byte-frozen.

---

### Task 2: Orphan sweeper and a dead-man watchdog for `--persist`

**Files:** new `scripts/orca-sweep-orphans.sh`; `scripts/orca-dispatch-role.sh`; `scripts/install-to-project.sh` (script lists); tests in `tests/debate.sh`, `tests/install.sh`

**The defect.** `--persist` implies `--no-reap`, so no background reaper starts. The only closer becomes the driver's EXIT trap, which cannot run on SIGKILL, a closed coordinator tab, a crashed shell, or an abort inside `ensure_terminal`. Each survivor is a permission-bypassed agent session with no owner.

**Why `orca-reap-task.sh` cannot be reused as-is** — verified, do not re-litigate:
- Its timeout path deliberately does not close (`"not closing (task may still be running)"`). It gives up; it is not a dead man's switch.
- It closes on dispatch status `completed|failed`. A persist tab reaches `completed` after round 1 and must survive for round 2. Attaching it would kill tabs between rounds.

So this needs a separate watchdog with inverted logic: close when the **owner** stops proving it is alive, regardless of dispatch status.

**What must become true**

1. A sweeper can be run at any time and closes terminals that are debate/role terminals by title, are absent from both `handles.json` and any live watchdog's ownership, and are older than an age threshold. It never touches a terminal it cannot positively identify as ours — an unrecognized title is left alone, always.
2. `--persist` starts a watchdog that outlives the dispatch but not the owner. The owner refreshes a liveness marker; when the marker goes stale past a TTL, the watchdog closes the tabs it owns and exits.
3. Normal driver exit leaves no watchdog process behind.

**Data contract — watchdog ownership**

Path: `$ORCH/debate-locks/<slug>.json`:

| field | meaning |
|---|---|
| `pid` | owning driver's pid |
| `slug` | debate slug |
| `handles` | array of handles the owner is responsible for |
| `heartbeatAt` | ISO-8601 UTC, refreshed by the owner |
| `ttlSeconds` | staleness threshold |

This file doubles as the concurrency lock for Task 3's `I3` fix: a driver that finds a fresh lock for a different slug must refuse to start rather than share tabs.

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** A terminal created with one of our titles and no `handles.json` entry, older than the threshold, is closed by the sweeper. A terminal with an unrelated title in the same list is not.
- [ ] **Step 2:** `kill -9` on a driver mid-round leaves no debate terminal alive after the TTL elapses. This is the criterion that matters most — demonstrate it, do not assert it.
- [ ] **Step 3:** A normal driver exit leaves no watchdog process running.
- [ ] **Step 4:** A second driver started for a different slug while a fresh lock exists refuses to start and says why.
- [ ] **Step 5:** Both suites pass, `bash -n` clean, installer re-run, `cmp` verified.
- [ ] **Step 6:** Commit.

---

### Task 3: Label-native anonymization

**Files:** `scripts/orca-debate-lib.sh`, `scripts/orca-debate-round.sh`, `scripts/orca-debate.sh`, `templates/roles.yaml`, `SKILL.md`, `README.md`, `docs/superpowers/specs/2026-07-29-multi-model-idea-debate-design.md`; tests in `tests/debate.sh`

**The defect.** The spec and `SKILL.md` state that proposals circulate under labels and model names never appear. Nothing delivers that:

- `label-map.json` — the whole key — is written into `round-2/`, the exact directory the round-2 spec instructs every debater to read.
- An anonymized copy differs from its named original by one stripped H1 line. One `diff` deanonymizes.
- The round-3 spec sends each debater to `round-1/<short>.md`, walking it into the directory of model-named originals.
- `manifest.json` sits inside the debate directory recording `{"debater": "claude", …}`.
- **Labels are positionally assigned from a roster whose default order is a public constant in the library.** `A=claude` is derivable from source alone — moving the key file out would not have closed this. Labels must be shuffled per debate.

Debaters run with permission-bypass flags, so none of this requires effort on their part.

**What must become true**

1. Raw round output is written under label names from the start (`round-1/A.md`), so there is no named original and no copying step. `debate_anonymize` and the proposal/critique copy sets disappear.
2. Label assignment is **shuffled per debate**, not derived from roster order.
3. The label mapping and the run manifest live outside the debate directory. Only the driver reads them.
4. No round spec points a debater at a path that reveals authorship.
5. The transcript re-attributes by short name at the end — the transcript is for the human and is never read by a debater.
6. **The docs stop overclaiming.** The achievable guarantee is: nothing instructs a debater to deanonymize, and no single `diff`, `glob`, or file read inside the debate directory reveals authorship. It is *not* cryptographic — a bypass-permissions debater can still read `dispatch-ledger.jsonl`, `handles.json`, and `orca terminal list` titles. Say that plainly in `SKILL.md`, the README security section, and the design spec, and record `read_only` in `templates/roles.yaml` as prompt-enforced rather than as fact.

**Data contract — label map**

Path: `$ORCH/debate-labels/<slug>.json` (outside the debate directory):

```
{"slug": "...", "roster": ["claude","codex","grok","gemini"], "labels": {"claude": "C", "codex": "A", ...}}
```

`roster` is recorded so a re-run with a different roster is detected. On mismatch the driver must refuse or rebuild rather than silently reusing labels — a stale map otherwise drops a participant's contribution or injects a ghost one.

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** Nothing inside a completed debate directory contains any of `claude`, `codex`, `grok`, `gemini` — filenames or contents. Assert this over the whole directory tree, not per file.
- [ ] **Step 2:** Two debates on the same roster produce different label assignments. Run it enough times to distinguish shuffling from coincidence.
- [ ] **Step 3:** A round-2 spec's read paths, followed literally, expose no authorship.
- [ ] **Step 4:** A re-run with a changed roster does not silently reuse a stale map.
- [ ] **Step 5:** Re-running the same slug does not let a previous run's output count as this run's. (Deferred finding `I1`: stale files currently pass the `-s` usability check.)
- [ ] **Step 6:** The transcript still attributes contributions by short name.
- [ ] **Step 7:** Both suites pass, `bash -n` clean, YAML parses, installer re-run, `cmp` verified.
- [ ] **Step 8:** Commit.

---

### Task 4: Stop leftover `worker_done` messages from closing the wrong tab

**Files:** `scripts/orca-wait-done.sh`, `scripts/orca-dispatch-role.sh` (docs/usage only), `templates/SCRIPTS.md`; tests in `tests/debate.sh`

**The defect.** Debaters are told to send `worker_done`; the debate path deliberately never consumes the inbox, because `orca orchestration check` consumes it and would race the reaper. A three-round debate therefore leaves up to twelve messages queued. The next unrelated supervised flow calls `orca-wait-done.sh`, which does `check --wait --types worker_done`, takes the first message, and — when invoked with `--role` as `orca-dispatch-role.sh --wait` does — resolves the close target from `handles.json` by role name rather than from the message. **A leftover debate message closes an unrelated role's tab and reports that task as complete.**

**Why draining is the wrong fix** — verified: `orca orchestration check` has no per-task selector (`--terminal`, `--unread|--peek|--all`, `--types`, `--inject`, `--wait`, `--timeout-ms` only). A drain would consume messages belonging to any concurrent flow. That is worse than the pollution.

**What must become true**

1. `orca-wait-done.sh` accepts a task filter. Given one, a message whose payload task id does not match is not acted on, and the wait continues under the original overall timeout rather than returning.
2. `orca-dispatch-role.sh --wait` passes the task id it just created, so it can only ever complete on its own message.
3. Without a filter, behavior is unchanged — this must not break existing callers.
4. The single-waiter assumption (two concurrent `orca-wait-done.sh` processes are not supported) is documented where a user will see it.

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** With a stubbed `orca` returning a `worker_done` for task X, `orca-wait-done.sh --task Y` does not close anything and keeps waiting. Prove the pre-fix code closes a tab.
- [ ] **Step 2:** The same stub with `--task X` closes the expected handle.
- [ ] **Step 3:** No `--task` argument reproduces today's behavior exactly.
- [ ] **Step 4:** A `check` response carrying several messages is handled — the filter must not only inspect the first.
- [ ] **Step 5:** Both suites pass, `bash -n` clean, installer re-run, `cmp` verified.
- [ ] **Step 6:** Commit.

---

### Task 5: Live verification — one complete round

**Files:** none expected. A defect found here is reported, not patched, unless the fix is obviously in scope.

**Why this task is the point.** Four live attempts produced zero debate output files. Until one `round-1/*.md` exists, the central claim of the whole branch is untested. Everything above is prerequisite.

**Before starting**

- [ ] **Step 1:** Confirm the runtime copies match source for every script (`cmp`). A live run against stale runtime copies proves nothing.
- [ ] **Step 2:** Record a terminal baseline: `orca terminal list --json`. Every terminal in it belongs to the user. Nothing in the baseline may be closed at any point.
- [ ] **Step 3:** Confirm the working tree is clean and committed, so a stray debater write is recoverable.

**The run**

- [ ] **Step 4:** One round only, via the **installed** copy. Bound the timeout. Four provider CLIs will be invoked; this spends the user's quota, so it runs once — diagnose before retrying.
- [ ] **Step 5:** While it is in flight, confirm the four debater tabs coexist and stay open after the first `worker_done` lands.

**What must be observably true afterward**

- [ ] **Step 6:** Four non-empty round-1 output files exist, under label names.
- [ ] **Step 7:** The manifest records four usable outputs, `flags` `ok`, no `lint-fail`.
- [ ] **Step 8:** No file in the debate directory names any model.
- [ ] **Step 9:** No terminal outside the baseline survives, and no journal line has a null handle.
- [ ] **Step 10:** `git status --porcelain` shows nothing outside the debate directory. A tracked-file modification is a Critical finding — report it with the diff, do not commit it.
- [ ] **Step 11:** After the run, dispatch one unrelated role with `--wait` and confirm the leftover debate messages do not close its tab or report false completion. This is Task 4's fix under real conditions.
- [ ] **Step 12:** `kill -9` a fresh driver mid-round and confirm no debate terminal survives the TTL. This is Task 2's fix under real conditions.

**Judgment, not just mechanics** — read the four outputs and report honestly:

- [ ] **Step 13:** Did each debater follow the required structure, name its own proposal's weakest link, and tag claims with `[출처: …]`?
- [ ] **Step 14:** Are the four proposals genuinely different, or four rewordings of one idea? The lenses are the feature's entire value. A flattering answer here is worth nothing.
- [ ] **Step 15:** Did any debater reveal its own model in its body despite the instruction?
- [ ] **Step 16:** Would a human reading the transcript get something worth four model invocations?

**Step 17:** Clean up: remove the debate directory, clear debater handles, re-run both suites.

---

## Deferred minors to fold in where already touching the file

Fix these only in the task that already edits the file; do not open new files for them.

| Finding | Task |
|---|---|
| Round exit 2 (quorum) vs exit 1 (usage) reported identically — the driver tells the user "did not meet quorum" for a usage error | 3 |
| Tab-close outcomes fully silenced, destroying the evidence needed to diagnose cleanup failures | 2 |
| `--dry-run` still writes the label map, so a partial-roster dry run poisons the next real run | 3 |
| No behavioral test that `--persist` selects STAY-OPEN rather than AUTO-CLOSE | 2 |
| `role_meta` and `handles_set` are two hand-maintained metadata tables that agree only by hand — add an assertion, not a refactor | 1 |
| `commands/dispatch.md`, `close.md`, `fallback.md` argument hints still omit `ui`/`reviewer` | 4 |
| `debate_lint`'s stderr is discarded, so a `lint-fail` never says which heading was missing | 3 |
| `--slug` is unsanitized and can escape the debates root | 3 |
| Test seams `ORCA_DEBATE_*` are live env vars that override the dispatcher in production — prefix them `ORCA_TEST_` | 2 |

Left for later, explicitly: tab titles not persisting (cosmetic, pre-existing for all six original roles — correct the YAML comments only), the brittle `orca status | grep` reachability check, no early exit once quorum is reached, and the unimplemented `agy` quota row in the spec.

## Merge gate

The branch merges when Tasks 1-4 are reviewed clean **and** Task 5 produced four real output files with no orphan terminals and no tracked-file modifications. If the misrouted-seed event recurs during Task 5, that is a merge blocker regardless of everything else — an unexplained cross-session delivery is not something to ship past.
