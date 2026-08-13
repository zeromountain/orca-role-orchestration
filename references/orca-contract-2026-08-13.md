# Orca orchestration contract — spike results (2026-08-13)

Measured against a live Orca runtime (`orca status --json` → `appVersion 1.4.181`),
using this repo's own `thrifty` (grok) launch command. See `CLAUDE.md` "Where role
facts actually live" for why grok/agy require the custom-argv path.

## S1-a — does `worker-release` close a reused role tab? **NO.**

Sequence: `terminal create --command 'grok --model grok-4.5 --permission-mode
bypassPermissions'` → `worker-start --task --terminal <handle>` → worker sends
`worker_done` → `worker-release --dispatch <id>`.

```json
{"state": "retained", "reason": "external_terminal", "processAction": "none", "archive": null}
```

`worker-show` confirms the classification is structural, not a fluke:

```json
"terminalResource": {
  "ownershipState": "external",
  "releaseState": "not_requested",
  "retainedReason": "external_terminal",
  "archive": {"source": null, "status": null}
}
```

Any terminal this skill pre-creates via `terminal create --command <custom argv>`
(required for grok/agy, and for the permission-bypass flags on all four CLIs) will
always be `ownershipState: "external"` to Orca. `worker-release` will never close it.
**Consequence:** `worker-release` cannot replace `terminal_close_and_verify` as the
close mechanism. It stays additive: call it for the archive attempt and the
structured state read, then fall back to our own close.

## S1-b — does `worker-start --terminal` accept a custom-argv terminal? **YES.**

`worker-start --task <id> --terminal <handle> --json` returned `state: "ready"`,
`stage: "input_accepted"`, effects `[{"kind":"terminal","action":"reused"}, ...]`.
The worker received the injected preamble and replied correctly. Confirmed for
grok; claude/codex/agy not independently spiked (same code path, no CLI-specific
branching in `worker-start`'s terminal attach — low risk).

## S1-c — does `worker-start` inject Run/task/dispatch identity, making our
manual RUN SCOPE block redundant? **YES.**

The worker's `worker_done` arrived with correct `taskId`/`dispatchId` in the
payload with no RUN SCOPE reminder text present in the spec at all — `worker-start`
built the full preamble itself (confirmed by reading it back via `worker-read`,
which showed the injected system message contains the exact `orca orchestration
send --from <handle> --dispatch-capability [redacted] --type worker_done ...`
recipe). `dispatch_tail_block`'s RUN SCOPE block (`orca-roles-lib.sh:216-226`)
is now provably unnecessary for the `worker-start` path. Only relevant if a
future change reverts to raw `dispatch --inject`.

## S1-d — does `display_name` on `task-create` round-trip through `task-list`? **YES.**

`task-create --display-name "[thrifty]"` → `task-list --json` returned
`display_name: "[thrifty]"` on the same task row, untouched. Sufficient to carry
role identity without a side-file ledger for that one field.

## Bonus finding — `worker-read` works independent of release state

Even on a `retained`/`external_terminal` dispatch, `worker-read --dispatch <id>`
returned the full hook-backed transcript (`source: "transcript"`, `provider:
"grok"`), including reasoning blocks and tool calls, with a paging `cursor`. This
is strictly better than our `terminal read` screen-scraping (`orca-roles-lib.sh:536,
1355,1399`) and does not depend on `worker-release` succeeding.

## Bonus finding — `worker-show` replaces hand-rolled tri-state liveness

`worker-show --dispatch <id>` returns `terminalResource.ownershipState` /
`retainedReason` directly. This is more precise than guessing from `terminal
list`'s `connected` field (`terminal_is_live`, `orca-roles-lib.sh:1476-1529`).
Worth querying once per reap cycle instead of/alongside `terminal_is_live`.

## S2 (Stage 3, 2-b spike) — `--retry-of` across roles: NOT viable as planned

Measured live: `worker-start --retry-of <old_dispatch_id>` on a task **refuses**
while the old dispatch is still active (`task_not_startable`). It only
succeeds after the old dispatch reaches a terminal state — `worker-stop`
(or `worker-abandon`) first, then `worker-start --retry-of` on a fresh
terminal. `worker-stop` also closes the old terminal itself
(`processAction: "closed_agent_terminal"`), which is convenient.

The bigger problem: `--retry-of` reuses the **same task, same frozen spec
text** — task-create is never called again, so the spec cannot be reworded
for the new attempt. Dispatched a `thrifty`-authored task
(`[ROLE=thrifty | grok-4.5] ...`) via `--retry-of` onto a fresh **agy /
Gemini 3.6 Flash** terminal and read the delivered preamble back: the
worker's TASK block still read `[ROLE=thrifty | grok-4.5] ...` verbatim —
a Gemini Flash fallback seat being told it is "ROLE=thrifty on grok-4.5".
Orca's own docs describe sending a follow-up message
(`orchestration send --to dispatch:<id> --subject "Follow-up" ...`) to
correct context on a retry, but workers only consume the inbox when
blocked/asked — a follow-up is not guaranteed to be read before the worker
acts on the stale spec.

**Conclusion:** `--retry-of` is well-suited to a **same-role crash
recovery** ("this role's worker vanished mid-task, retry the identical work
on a fresh terminal of the same role") — the spec text stays accurate
because the role/model framing does not change. It is NOT suited to
`orca-fallback-on-limit.sh`'s actual job (primary role → a DIFFERENT
fallback role/model), because the framing text is exactly what needs to
change and can't. `orca-fallback-on-limit.sh` keeps its existing
new-task-with-a-`[FAILOVER from ...]`-wrapper design; `--retry-of` is wired
into `orca-dispatch-existing.sh` for the same-role recovery case only.

## Net effect on the plan

| Stage 1 item | Result | Plan consequence |
|---|---|---|
| S1-a | retained/external | **Hybrid, not replace**: `worker-release` always called (archive attempt + state read), `terminal_close_and_verify` fallback stays the actual close mechanism |
| S1-b | accepted | `worker-start --terminal` safe to adopt for all four roles |
| S1-c | confirmed | RUN SCOPE block removable when the path is `worker-start` |
| S1-d | confirmed | ledger can drop the role column once `task-create --display-name` is adopted everywhere |
