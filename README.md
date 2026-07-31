# Orca Role Orchestration

An installable Agent Skill and project scaffold for routing Orca Agent IDE work across six model-specific roles, plus a four-model idea-debate mode.

| Role | Default model | Best for |
|---|---|---|
| `architect` | Claude Opus 5 | Architecture, planning, high-risk review |
| `executor` | GPT-5.6 Sol via Codex | Implementation, debugging, verification, raster images via `$imagegen` |
| `thrifty` | Grok 4.5 | Exploration, research, small low-risk changes |
| `ui` | Gemini 3.6 Flash (Medium) via `agy` | User-visible surface drafts, always routed back to architect for approval |
| `reviewer` | Claude Opus 5 | Final pre-merge gate only — APPROVE/BLOCK, never implements |
| `fallback` | Gemini 3.6 Flash (Medium) via `agy` | Continuity after rate or session limits |

Bootstrap starts the four primaries (`architect`/`executor`/`thrifty`/`fallback`); `ui` and
`reviewer` tabs are created on their first dispatch. The idea-debate mode below adds four more
read-only `debater_*` seats, one per provider.

The defaults are intentionally opinionated. Launch commands live in `scripts/orca-roles-lib.sh` (`role_meta` / `role_launch_cmd`), not `roles.yaml` — edit that library if you need different model IDs or CLI flags.

## Prerequisites

- Orca Agent IDE with **Settings → Experimental → Agent orchestration** enabled
- `orca`, `claude`, `codex`, `grok`, and `agy` available on `PATH`
- Python 3 and Bash

Check the local runtime before bootstrapping:

```bash
orca status --json
which orca claude codex grok agy
```

## Install for Claude Code (plugin marketplace)

This repo is a **self-contained marketplace** (same pattern as Superpowers): root `SKILL.md` + `.claude-plugin/` manifests. Layout stays at repo root so `scripts/install-to-project.sh` paths keep working.

```text
/plugin marketplace add zeromountain/orca-role-orchestration
/plugin install orca-role-orchestration@orca-role-orchestration
```

CLI:

```bash
claude plugin marketplace add zeromountain/orca-role-orchestration
claude plugin install orca-role-orchestration@orca-role-orchestration
```

Local dry-run from a checkout:

```bash
claude plugin validate .
claude --plugin-dir "$(pwd)"
# skill namespace: /orca-role-orchestration:…
```

Refresh after new commits (plugin version is SHA-based — no pin field in `plugin.json`):

```text
/plugin marketplace update orca-role-orchestration
/plugin update orca-role-orchestration@orca-role-orchestration
```

Claude plugin install loads the skill for Claude Code. For **project scaffold** and multi-agent paths (`~/.agents/skills`, Codex/Grok), also use `install-skill.sh` below (or run `install-to-project.sh` from the plugin cache / a clone).

## Install for Codex (plugin marketplace)

Codex discovers this repo via `.agents/plugins/marketplace.json` and loads the plugin from `.codex-plugin/plugin.json` (root single skill, `skills: "./"`, empty `hooks: {}` so no Claude hooks leak in).

```bash
codex plugin marketplace add zeromountain/orca-role-orchestration
codex plugin add orca-role-orchestration@orca-role-orchestration
```

Local dry-run from a checkout:

```bash
codex plugin marketplace add "$(pwd)"
codex plugin add orca-role-orchestration@orca-role-orchestration
codex plugin list
```

Refresh marketplace snapshots after new commits:

```bash
codex plugin marketplace upgrade
```

Same note as Claude: plugin install loads the skill into Codex; project scaffold still uses `install-to-project.sh` from a full skill root (`install-skill.sh`, clone, or plugin cache).

## Install or update the global skill (multi-agent)

Same command installs and updates (clone-or-pull + optional multi-agent symlinks):

```bash
# from a checkout, or curl raw from GitHub
curl -fsSL https://raw.githubusercontent.com/zeromountain/orca-role-orchestration/main/scripts/install-skill.sh | bash
# or:
./scripts/install-skill.sh
```

Canonical path: `~/.agents/skills/orca-role-orchestration`. If `~/.claude/skills`, `~/.codex/skills`, or `~/.grok/skills` exist, they get a symlink to that checkout.

Restart or reload your agent so it discovers `SKILL.md`.

## Install or update the project scaffold

**One flagless command** — safe to re-run anytime:

```bash
~/.agents/skills/orca-role-orchestration/scripts/install-to-project.sh \
  --project-root "$(pwd)"
```

| Layer | Path | On re-run |
|-------|------|-----------|
| Managed routing | `.orca/orchestration/roles.yaml` | Always refreshed (`.bak` if changed) |
| Your hints | `.orca/orchestration/project_hints.yaml` | Created once; **never** overwritten |
| Personas | `.orca/orchestration/personas/*.md` | Refresh if unmodified; skip if forked |
| Scripts / docs | `scripts/`, `PLAYBOOK.md`, … | Always refreshed |
| Version stamp | `install-manifest.json` | Written every run |

Recovery (overwrite forked personas too):

```bash
…/install-to-project.sh --project-root "$(pwd)" --reset
```

Then bootstrap workers:

```bash
orca repo add --path "$(pwd)" # only if the project is not already in Orca
.orca/orchestration/scripts/orca-bootstrap-roles.sh --worktree "path:$(pwd)"
```

See [`SKILL.md`](./SKILL.md) for routing behavior and [`templates/PLAYBOOK.md`](./templates/PLAYBOOK.md) for the supervised lifecycle.

## Using the skill

Once the skill is loaded, ordinary requests route themselves — the scripts below are what the
coordinator runs on your behalf, not something you normally type.

| You ask for | Routed to | Shape |
|---|---|---|
| "Plan this refactor before anyone touches code" | `architect` | plan only, no edits |
| "Implement the approved plan and get the build green" | `executor` | implement + verify |
| "Map where auth lives" / "prototype this quickly" | `thrifty` | read-only survey, cheap changes |
| "Draft the settings screen" | `ui` → `architect` | draft, then approval before implementing |
| "Final check before merge" | `reviewer` | APPROVE / BLOCK, never implements |
| "Make a hero image" | clarity gate → `executor` | Codex `$imagegen` only |
| "Opus hit its limit — keep going" | `fallback` | continuity on Gemini Flash |
| "Let's sharpen this idea" | four `debater_*` seats | [idea debate](#idea-debate) |

Korean triggers work the same way (`역할 오케스트레이션`, `모델별 역할 분리`, `이미지 생성`,
`아이디어 토론`, `니치 찾기`).

Slash commands are the explicit form of the same routes — `/orca-role-orchestration:install`,
`:bootstrap`, `:dispatch`, `:wait`, `:fallback`, `:debate`, `:close` in Claude Code, and
`/orca-install`, `/orca-bootstrap`, `/orca-dispatch`, … in Codex.

### Plan → implement → review

The standard DAG, dispatched by hand. Each tab auto-closes when its task completes — there is no
close step:

```bash
D=.orca/orchestration/scripts/orca-dispatch-role.sh

# 1. Opus plans. No file edits in this pass.
"$D" architect --spec "Plan only: add refresh-token rotation to the auth service.
Constraints: follow AGENTS.md; no schema migration in this pass.
Scope: src/auth/**. Done: numbered plan + risk list, zero file edits."

# 2. Sol implements the approved plan and blocks until it reports back.
"$D" executor --wait --spec "Implement the approved plan (rotation + revoke-on-reuse).
Scope: src/auth/**, tests/auth/**. Done: pnpm typecheck && pnpm test:auth both green."

# 3. Opus gates the diff. Review only.
"$D" reviewer --spec "Pre-merge gate on the auth diff. APPROVE or BLOCK with reasons.
Do not implement or rewrite."
```

Cheap work skips the ladder entirely — `"$D" thrifty --spec "Read-only: list every call site of
issueToken(). No edits."`

### Waiting on a result

`--wait` on dispatch already pins the wait to that dispatch's own task. Waiting separately means
passing the task id dispatch printed, otherwise the first matching message wins — including a
leftover one from an unrelated flow:

```bash
.orca/orchestration/scripts/orca-wait-done.sh --task task_abc123 --timeout-ms 900000
```

A timeout or `count:0` is a checkpoint, not a failure.

### Image generation

Raster images route to `executor` through Codex `$imagegen`. If subject, intended use, or
destination is missing, the coordinator asks before dispatching rather than inventing them:

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh executor --spec "
Use Codex \$imagegen skill only
(read \${CODEX_HOME:-\$HOME/.codex}/skills/.system/imagegen/SKILL.md).
Goal: dark-mode hero image for the landing page.
Subject: a single orca breaching over a calm night sea.
Use: web hero, 16:9.
Destination: public/img/hero.png
Avoid: text, logos, brand marks.
Done: final path + mode (built-in|CLI).
"
```

Vector icon sets, repo-native logos, and shapes better done in CSS/SVG are not `$imagegen` work.

### After a rate or session limit

Hand the remaining work to the fallback seat instead of retrying the limited primary:

```bash
.orca/orchestration/scripts/orca-fallback-on-limit.sh --from architect \
  --spec "Continue: finish the rotation plan.
Done so far: threat model + token schema. Remaining: revoke-on-reuse and rollout steps."
```

Fallback is continuity, not a default quality lane.

## Idea debate

Four models argue an idea into a niche direction — propose, critique each other anonymously,
then converge:

```bash
.orca/orchestration/scripts/orca-debate.sh --topic "your idea or open question"
```

Transcript lands in `.orca/orchestration/debates/<slug>/` (gitignored); the decision document goes
to `docs/ideas/`. Round output is written under a shuffled label from the start (`round-1/A.md`,
never a model-named file); the label map and per-round manifest live outside the debate directory
entirely, in `.orca/orchestration/debate-labels/` and `debate-manifests/` — nothing inside the
debate directory itself, in a filename or in file contents, ever names a debater. See the
anonymity guarantee and its limits under Security below. Only one debate runs at a time: starting
a second one — same slug or a different one — while a debate is still live is refused, since
terminals are reused per-role globally and two concurrent debates would otherwise collide in the
same four sessions (a same-slug collision would also reset the live debate's tracked handles,
leaving its tabs unprotected from the new driver's own cleanup).

## Security

The default launch commands disable or bypass agent permission checks. Use them only in trusted repositories and review the commands before running `orca-bootstrap-roles.sh`. Remove the bypass flags if you want each provider's normal approval boundaries.

Generated `.orca/orchestration/handles.json` files are local runtime state and must not be committed.

**Idea-debate anonymity is not cryptographic.** The achievable guarantee is: nothing instructs a
debater to deanonymize, and no single `diff`, `glob`, or file read *inside the debate directory*
reveals authorship. Debaters run under the same permission-bypass flags as every other role, so
this is enforced by the dispatch spec and persona (`templates/roles.yaml`'s `read_only` field is
prompt-enforced, not a sandboxing fact) — a debater that ignored its instructions could still read
`dispatch-ledger.jsonl`, `handles.json`, `terminal-journal.jsonl`, or `orca terminal list` titles,
none of which live inside the debate directory but none of which are hidden from that process
either. The transcript (`transcript.md`, inside the debate directory) is the one deliberate
exception: it re-attributes each contribution by real short name for the human reader, written
only after the debate has concluded and never referenced by any round spec.

## License

MIT — see [`LICENSE`](./LICENSE).
