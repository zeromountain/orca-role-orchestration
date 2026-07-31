# Terminal Readiness Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop injecting keystrokes into provider CLIs that have not finished booting, so the four-model debate produces output instead of four timeouts.

**Architecture:** A readiness gate built from terminal reads (the CLI offers no readiness condition), applied at both points that write into a terminal — seeding and dispatch injection — plus a driver preflight that fails in seconds instead of after a 25-minute round.

**Tech Stack:** Bash 3.2, Python 3 heredocs, `orca` CLI v1.4.155.

**Predecessors:** `2026-07-29-multi-model-idea-debate.md` built the feature; `2026-07-30-debate-critical-fixes.md` closed four Critical findings. Both are committed on `feat/multi-model-idea-debate`.

## The defect, established by evidence

Five live runs produced zero debate output. All four debaters timed out every time, and their terminals showed CLI-specific damage: `claude` and `codex` **exited**, `grok` stalled at its first-run menu, `agy` sat at an empty prompt.

`terminal-journal.jsonl` records the four debater terminals created at `05:10:47 / :50 / :53 / :56` — gaps of 2.70s, 3.76s, 2.67s. The entire per-debater pipeline (create → rename → `wait_idle` → seed send → task-create → `wait_idle` → `dispatch --inject`) fit inside each gap. A `claude` cold start alone exceeds that.

The gate is `wait_idle`'s `orca terminal wait --for tui-idle`. **`tui-idle` means "the TUI stopped redrawing", and a blank, not-yet-drawn screen satisfies it instantly.** Both the seed and the injection therefore landed in a booting TUI.

**A disproven hypothesis, recorded so nobody re-derives it:** the earlier theory that seeding a menu-driven TUI selects a menu entry (grok's menu contains `Quit`) is **wrong**. A grok terminal displaying its first-run menu was sent text directly and accepted it, responding normally.

**Counter-proof that everything else works.** Running the identical stages by hand with real pauses: `claude` launched to a ready prompt, accepted the seed and correctly acknowledged its role, accepted a dispatch of the real R1 propose spec, researched the literature, wrote a 13,489-byte proposal with all four required headings and 22 source tags, sent `worker_done`, reached `status=completed`, and went idle awaiting round 2. Anonymity held — the only model-name matches were inside a citation URL. The orchestration layer, the prompts, and the anonymity design are all sound.

## Why this is not only a debate bug

The 74 pre-existing successful dispatches in this project mostly took `ensure_terminal`'s reuse path (`handles_get` → live → return), which never touches create or seed. `orca-bootstrap-roles.sh` happens to do all four creates first and seed afterwards, so its first terminal gets 10s+ of boot time — a structural accident, not a guarantee. One slow boot or one new first-run screen breaks it. The gate must therefore protect the shared lifecycle path, not just the debate.

## Global Constraints

- **Bash 3.2** (macOS). No `declare -A`, no `mapfile`, no `${var,,}`.
- `set -euo pipefail` in executable scripts. Sourced libraries must not set shell options.
- **Command substitution does not inherit `errexit`**; bash 3.2 has no `inherit_errexit`. Check statuses explicitly. This has bitten every task across both predecessor plans.
- `tests/debate.sh` and `tests/install.sh` stay **runtime-free** and run under `set -euo pipefail`. `assert()` runs its command as an `if` condition so `-e` never trips on it; anything else expected to fail must be if-guarded or `|| true`.
- No new runtime dependencies — Bash and Python 3 only.
- **Dual-copy discipline:** every script exists at `scripts/<name>.sh` and `.orca/orchestration/scripts/<name>.sh`. A task is not done until `./scripts/install-to-project.sh --project-root "$(pwd)"` is re-run and `cmp` confirms byte-identical copies. Running live against stale runtime copies is how the first smoke test failed.
- **Do not touch:** `lock_handle_claimed_elsewhere` / `lock_is_fresh` / the owner-alive-only claim rule (a freshness-gated variant was tried and reverted); the label-native debate layout; shuffled label assignment; the `--task` filter in `orca-wait-done.sh`.
- **Assert your fixture is what you think it is before asserting on behavior.** In nearly every fix round of both predecessor plans, a fixture failed to model reality.

## Observed data — the design input

Collected live, from real terminals. Treat as starting evidence, not a complete pattern set.

| CLI | Ready appearance | Not-ready appearance |
|---|---|---|
| `claude` | `❯` prompt plus a status line containing `bypass permissions on` | blank/undrawn screen |
| `grok` | `❯` prompt (may sit below a first-run menu) | splash art; menu listing `New worktree` / `Resume session` / `Changelog` / `Quit` |
| `agy` | `>` prompt after an `Antigravity CLI` banner | banner still drawing |
| `codex` | not captured ready | exited before capture |

`orca terminal wait --for` supports only `exit` and `tui-idle` — there is no readiness condition, confirmed from `--help`. `orca terminal read --terminal <h> --json` returns `result.terminal.tail` (array of recent lines) and `result.terminal.status`; `orca terminal show` returns a `preview` string.

---

### Task 1: Distinguish "gone" from "cannot tell", and isolate bootstrap failures

**Files:** `scripts/orca-roles-lib.sh`, `scripts/orca-bootstrap-roles.sh`, `scripts/orca-close-role.sh`; tests in `tests/debate.sh`

**Why first:** Task 2 tightens the gate. A tightened gate that returns failure from `seed` would abort `orca-bootstrap-roles.sh` mid-loop under `set -euo pipefail`, stranding already-created permission-bypassed terminals. That regression must be impossible before the gate lands.

**Defect A — `terminal_is_live` conflates two different facts.** It returns "definitely not live" whenever `connected` is falsy, without distinguishing a handle **absent from the list** (genuinely gone) from one **present but momentarily not connected** (a flap). Observed live: cleanup logged `Handle … already gone (ok)` and skipped a close, and immediately afterward that terminal reported `connected: True` and `terminal_is_live` returned 0. An orphaned permission-bypassed session survived a driver that believed it had cleaned up.

**Defect B — closes are not verified.** The close path reports success without confirming the terminal actually went away.

**Defect C — bootstrap has no failure isolation.** It calls `seed` as a bare statement and writes `handles.json` at the very end, so any per-role failure aborts the run with earlier terminals unrecorded.

**What must become true**

1. `terminal_is_live` returns "definitely not live" only when the handle is **absent** from a successfully-retrieved terminal list. Present-but-not-connected is "cannot tell" (exit 2), which never authorises a close. A list that could not be retrieved at all remains "cannot tell".
2. After attempting a close, the code confirms the terminal is gone. A terminal still live after a close attempt is reported loudly, not silently swallowed.
3. `orca-bootstrap-roles.sh` records each role's handle as soon as it exists, collects per-role failures instead of aborting the loop, and exits non-zero at the end with a summary naming which roles failed and what remains.

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** With a stubbed `orca` whose `terminal list` includes the handle with `connected: false`, `terminal_is_live` reports "cannot tell" and `orca-close-role.sh` does not treat it as already gone. Prove the pre-fix code does.
- [ ] **Step 2:** With the handle absent from the list, `terminal_is_live` reports "definitely not live".
- [ ] **Step 3:** With a stub whose close silently fails (terminal still listed and connected afterward), the close path reports the failure loudly and exits non-zero.
- [ ] **Step 4:** With a stub that fails `seed` for the second of four roles, bootstrap still records handles for every terminal it created, still attempts the remaining roles, and exits non-zero naming the failed role. Prove the pre-fix code aborts and strands handles.
- [ ] **Step 5:** Both suites pass, `bash -n` clean, installer re-run, `cmp` verified.
- [ ] **Step 6:** Commit.

**Regression warning:** `terminal_is_live` is called by `ensure_terminal`, `orca-close-role.sh`, and `orca-reap-task.sh`. Widening exit 2 changes each. Confirm none of them now skips a close it must perform, or performs one it must not.

---

### Task 2: The readiness gate

**Files:** `scripts/orca-roles-lib.sh`, `scripts/orca-dispatch-role.sh`; tests in `tests/debate.sh`

**What must become true**

1. A library function decides whether a terminal is ready to receive input, from what is actually on its screen. It **polls until a deadline** rather than answering once — a booting CLI becomes ready given seconds, and an immediate verdict would reproduce today's defect with extra steps.
2. The gate runs **before seeding** in `ensure_terminal` and **before `dispatch --inject`** in `orca-dispatch-role.sh`. Both write into the terminal; both currently rely on `tui-idle` alone.
3. Not-ready is reported with **what was on screen**, so a human can act on it. Twenty-five minutes of silence is the failure this exists to eliminate.
4. For `debater_*` roles the existing post-seed marker check — currently informational — becomes a **hard gate with retries**: if the seed's own marker never appears, seeding failed and the caller must know. Keep it advisory for the six pre-existing roles, whose behavior must not change.

**Gate composition.** Combine three signals rather than trusting one, because a positive prompt pattern alone will silently break at the next CLI release:

- a **minimum elapsed time** since terminal creation, plus `tui-idle` as today;
- a **negative** check — known not-ready markers (splash art, first-run menu entries such as `Quit` / `Resume session` / `Select`, trust or theme prompts) mean not ready, regardless of anything else;
- a **positive** check — a known prompt pattern per CLI when one is available, treated as confirmation rather than as the sole requirement.

Start the pattern sets from the Observed data table above and say in your report which patterns you added and why.

**Do not attempt to dismiss a first-run screen by sending keystrokes.** Accepting a trust dialog on the user's behalf is not something this tool may do. The correct boundary is to report precisely which CLI is sitting on which screen so the user can clear it once, by hand.

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** With a stubbed terminal whose screen is blank, the gate does not report ready, and polls rather than answering immediately.
- [ ] **Step 2:** With a screen showing a first-run menu, the gate reports not-ready and its message names the marker it matched.
- [ ] **Step 3:** With a screen showing a ready prompt, the gate reports ready.
- [ ] **Step 4:** A screen that becomes ready partway through the polling window is detected — the gate must not latch its first verdict.
- [ ] **Step 5:** `ensure_terminal` does not seed a not-ready terminal, and `orca-dispatch-role.sh` does not inject into one. Prove both, and prove the pre-fix code does both.
- [ ] **Step 6:** For a `debater_*` role whose seed marker never appears, `seed` fails after its retries and the caller reports it. For a pre-existing role, the same condition stays advisory.
- [ ] **Step 7:** Both suites pass, `bash -n` clean, installer re-run, `cmp` verified.
- [ ] **Step 8:** Commit.

**Regression warning:** this is the shared lifecycle path for all six pre-existing roles. A pattern set that misjudges a ready terminal blocks ordinary dispatch. Design the failure as "poll until the deadline, then fail with the screen contents", never "fail fast on first mismatch".

---

### Task 3: Driver preflight and cleanup that verifies itself

**Files:** `scripts/orca-debate.sh`, `scripts/orca-debate-lib.sh`; tests in `tests/debate.sh`

**What must become true**

1. `orca-debate.sh` confirms **all** debater seats are created, seeded, and ready **before creating any orchestration task**. If a seat cannot be made ready, the debate aborts then — with each CLI's screen state — rather than dispatching into it and discovering the failure at the round timeout. This keeps the one-command flow; the user is not required to bootstrap first.
2. Cleanup verifies its closes (Task 1's guarantee) and, when a handle could not be confirmed closed, **leaves the lock file in place** as a breadcrumb so the orphan sweeper can find it. The sweeper's stale-lock path is the only detector for a handle the driver believed it had handled, and removing the lock on a clean exit blinds it — observed live, where a genuine orphan produced `candidates=0`.

**Acceptance criteria (behavioral)**

- [ ] **Step 1:** With one seat stubbed to never become ready, the driver aborts before any `task-create`, and its message names that seat and shows its screen.
- [ ] **Step 2:** With all seats ready, the driver proceeds exactly as today.
- [ ] **Step 3:** With a close that cannot be confirmed, the lock file survives cleanup and the sweeper subsequently reports that handle as a candidate. Prove the pre-fix combination reports `candidates=0`.
- [ ] **Step 4:** With all closes confirmed, no lock file is left behind and no watchdog process survives.
- [ ] **Step 5:** Both suites pass, `bash -n` clean, installer re-run, `cmp` verified.
- [ ] **Step 6:** Commit.

---

### Task 4: Live verification

**Files:** none expected. A defect found here is reported, not patched, unless the fix is obviously in scope.

**Before starting**

- [ ] **Step 1:** `cmp`-verify every runtime copy against source.
- [ ] **Step 2:** Record a terminal baseline. Everything in it belongs to the user and must never be closed.
- [ ] **Step 3:** Confirm the working tree is clean and committed.

**The run**

- [ ] **Step 4:** One round, via the installed copy, with a bounded timeout. Four provider CLIs will be invoked — this spends the user's quota, so diagnose before retrying rather than re-running.
- [ ] **Step 5:** While in flight, confirm the four seats reach ready and the preflight passed before any task was created.

**What must be observably true afterward**

- [ ] **Step 6:** Four non-empty round-1 outputs under label names.
- [ ] **Step 7:** Manifest records four usable outputs, no `lint-fail`.
- [ ] **Step 8:** No file in the debate directory names any model.
- [ ] **Step 9:** No terminal outside the baseline survives; no journal entry has a null handle; the sweeper reports no candidates.
- [ ] **Step 10:** `git status --porcelain` shows nothing outside the debate directory.
- [ ] **Step 11:** A subsequent unrelated dispatch with `--wait` is not completed or closed by leftover debate messages.
- [ ] **Step 12:** `kill -9` a fresh driver mid-round; no debate terminal survives the TTL.

**Judgment, not just mechanics**

- [ ] **Step 13:** Did each debater follow the required structure, name its own weakest link, and tag claims with `[출처: …]`?
- [ ] **Step 14:** Are the four proposals genuinely different, or four rewordings? The single-seat probe produced a real research finding — whether four seats produce four *distinct* ones is the open question this feature exists to answer.
- [ ] **Step 15:** Did any debater reveal its own model in its body?
- [ ] **Step 16:** Would a human reading the transcript get something worth four model invocations?

**Step 17:** Clean up and re-run both suites.

## Merge gate

Tasks 1-3 reviewed clean, **and** Task 4 produced four real output files with no orphans and no tracked-file modifications. The single-seat probe already proved one seat can do this; four seats concurrently is what remains unproven.
