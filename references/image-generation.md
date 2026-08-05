# Image generation via Codex `$imagegen`

Read before dispatching any raster image work.

Applies to a **new or edited raster image**: hero, mockup photo, illustration,
sprite, product shot, transparent cutout, and similar.

**Not** this path: extending an SVG/vector icon set, a logo that must match
repo-native vectors, or simple shapes better done in HTML/CSS/SVG.

## 1. Route to executor

Always `executor` (Codex). Never `thrifty`/Grok or Claude image tools for these
tasks — the spec must mandate the Codex `$imagegen` skill only
(`${CODEX_HOME:-$HOME/.codex}/skills/.system/imagegen/SKILL.md`).

## 2. Clarity gate — coordinator, BEFORE dispatch

If the brief is missing a success-critical slot, **ask the user first**. Do not
invent brand names, extra subjects, or marketing copy.

| Slot | Ask when missing |
|------|------------------|
| Subject | what is in the frame |
| Intended use | hero, ad, sprite, preview-only, … |
| Destination | project path vs preview-only (if project-bound) |
| Style / constraints | only if the user cares (medium, palette, no text, aspect) |
| Edit target | for edits: which file, and what must stay unchanged |

If the request is already specific enough, skip the questions and dispatch.

## 3. Dispatch

```bash
.orca/orchestration/scripts/orca-dispatch-role.sh executor --spec "
Use Codex \$imagegen skill only
(read \${CODEX_HOME:-\$HOME/.codex}/skills/.system/imagegen/SKILL.md).
Goal: <one-sentence deliverable>
Subject: …
Use: …
Style: …
Destination: <workspace path or preview-only>
Constraints/Avoid: …
Done: final path(s) + mode (built-in|CLI)
"
```

## 4. Rules the spec must carry

- Built-in `image_gen` path by default; CLI fallback only after the user confirms.
- Project-bound assets: copy the final file into the workspace, report the absolute path.
- Do not overwrite an existing asset unless the user asked to replace it.
- If a success-critical detail is still missing, escalate and ask — do not invent it.
