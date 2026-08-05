# Changelog

Managed files are overwritten on every `install-to-project.sh` run, so this is
the record of what changed under an existing install. Newest first.

## Unreleased

This branch was written against a four-role scaffold and merged into `main`
after it had independently grown a six-role model, an idea-debate mode, a
terminal-readiness gate, and a Run-scope requirement. Several fixes below
converged with equivalent, more thorough fixes already on `main` — those are
noted inline; the merge kept `main`'s mechanism and layered this branch's
fixes on top rather than duplicating either.

### Fixed — worker terminal leaks

- **Reaper no longer expires silently.** `orca-reap-task.sh` collapsed every
  unreadable `dispatch-show` response into `"unknown"` and kept polling, then
  hit its 1-hour timeout, printed a line and exited **0** without closing. Any
  change to that command's JSON shape leaked one idle worker tab per dispatch,
  with a success exit code. Parse failures are now distinguished from a pending
  status, bounded to 5 consecutive attempts, recorded as `reap_failed`, and
  exited non-zero.
- **A daemon hiccup no longer leaks or duplicates terminals.** `terminal_is_live`
  returned the same code for "confirmed gone" and "`orca terminal list` failed".
  The reaper read that as already-gone and skipped the close; `ensure_terminal`
  read it as dead and created a **second** terminal for a role that already had a
  live one. `main` independently converged on the same tri-state (live / gone /
  unknown) fix, more thoroughly — it also distinguishes a handle that is present
  but momentarily `connected:false` from one genuinely absent, which this branch
  did not — so the merge kept `main`'s version.
- **Concurrent ledger writers no longer drop rows.** One background reaper runs
  per in-flight dispatch, and `orca-wait-done.sh` may run alongside them. All did
  unlocked full-file read-modify-write over `dispatch-ledger.jsonl`, so the loser
  silently discarded other tasks' rows. All state writes now take an `fcntl` lock
  and land via temp + `os.replace`, including the dispatch-time append.
- **A corrupt `handles.json` no longer spawns a second fallback terminal.**
  `orca-fallback-on-limit.sh` could not tell "unreadable file" from "no fallback
  role" and created one on the guess. It now aborts with a repair hint.
- **Close failures are reported, not swallowed.** All three copies of a plain
  "close, then trust the exit code" block used to print "ok if already gone"
  regardless of the real outcome. `main` independently built the fix as
  `terminal_close_and_verify()` — it re-checks liveness after the close
  attempt instead of trusting the close call's own reported success, which is
  stronger than this branch's original close-and-trust design, so the merge
  kept `main`'s version and layered this branch's escalation on top: a reaper
  that cannot confirm a close now records `close_failed` / `close_undetermined`
  in the ledger and (for the separate case of an unreadable dispatch status)
  exits non-zero instead of polling silently to its 1-hour timeout.

### Added

- **`orca-status.sh`** (`/…:status`, `/orca-status`) — doctor in one command:
  preflight (Orca reachable, role CLIs on PATH), per-role handle liveness,
  dispatches that never reached `closed`, and reaper pids. Exit 1 when something
  needs attention. This is the only place `reap_failed` / `close_failed` surfaces.
- **`roles.local.json`** — optional, user-owned, never overwritten. Repoints a
  role's `model` / `launch_command` / `title` / `agent` without forking a script,
  for consumers who do not have all four default CLIs. Role names stay fixed.
- **Role-CLI preflight and `--roles`** in bootstrap. A missing `grok` used to
  produce a tab that died with *command not found*, a soft warning, and a
  recorded-but-dead handle. Now it fails up front and suggests a subset.
- **`--dry-run` and `--uninstall`** for `install-to-project.sh`, plus a `python3`
  preflight. Uninstall keeps `project_hints.yaml`, `roles.local.json`, forked
  personas and runtime state, and prints what it left.
- **Test suites and CI.** `tests/runtime.sh` drives every runtime script against
  a fake `orca` on `PATH` (with a failure-injection hook, so the failure paths
  above are actually covered); `tests/repo-lint.sh` validates the four plugin
  manifests, the Claude/Codex command pairs, and personas. GitHub Actions runs
  all three suites plus `shellcheck` on macOS and Ubuntu.

### Changed

- **Bootstrap is idempotent and resumable.** This branch's fix called
  `ensure_terminal` per role instead of reimplementing create → wait → seed →
  record. `main` independently arrived at the same idempotent-recreate design
  for `ensure_terminal` itself, more thoroughly — a per-terminal creation
  journal, durable-handle-before-seed ordering, and per-role failure isolation
  in bootstrap's own three-phase loop — so the merge kept `main`'s version.
- **Role metadata exists once.** The title/model/agent triple was declared
  twice in executable code — `role_meta()` and a separate dict inside
  `handles_set()` — and had drifted: bootstrap seeded workers with the
  display name ("Claude Opus 4.8"/"Claude Opus 5") while dispatch seeded the
  model ID ("claude-opus-4-8"/"claude-opus-5"), so the same role was told
  different things depending on who started it. `role_meta()` is now the
  only source, and it also resolves `roles.local.json` overrides, so a
  customized role's recorded metadata is truthful too.
- **Backups rotate.** A changed managed file still becomes `.bak`, but an
  existing `.bak` moves to `.bak.1`, `.bak.2`, … A fork used to survive one
  upgrade and be silently lost on the next.
- **`.gitignore` covers all runtime state** — `dispatch-ledger.jsonl`, `*.lock`
  and `reapers/` as well as `handles.json`. Consumers had a permanently dirty
  `git status` from the first dispatch. Reaper logs are pruned to the last 50.
- **`SKILL.md` slimmed** 311 → 189 lines; layout, marketplaces, the full routing
  table, the DAG catalog and the image-gen gate moved into `references/`, read on
  demand. This file loads on every skill trigger in every consumer session.
- **`orca status` reachability is parsed**, not matched against the literal
  string `"reachable": true`, which a whitespace change would have broken.
- Removed the stale `limit_failover.detect_patterns` copy from `roles.yaml`; it
  had no consumer and had already drifted from `LIMIT_RE` in the script.
- Hardened `orca-wait-done.sh`: the `COUNT` field is `shlex.quote`d like its
  siblings (it was the one unquoted value reaching `eval`), and a non-numeric
  count no longer aborts the coordinator.

## v1.0.0

Initial release: four-role scaffold, personas, supervised dispatch with automatic
tab close, limit failover, and dual Claude/Codex plugin marketplaces.
