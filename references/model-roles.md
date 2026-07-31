# Model role strengths (routing background)

Research snapshot used to design the six Orca roles and the four-model idea-debate mode.

| Role | Model | CLI | Strengths | Weaknesses |
|------|-------|-----|-----------|------------|
| architect | Claude Opus 5 | `claude` | Judgment, honesty, long-horizon agents, high-stakes review, enterprise workflows | Higher token use; not ideal for bulk low-risk grind |
| executor | GPT-5.6 Sol | `codex` | Collaborative execution, persistence, terminal/tool loops, knowledge work, close the loop, Codex `$imagegen` raster assets | Can over-engineer open-ended architecture; weaker pure taste/judgment vs Opus |
| thrifty | Grok 4.5 | `grok` | Speed, cost, codebase navigation, multi-file engineering, prototypes, Office artifacts | Less “taste” for full-delegation design/writing |
| ui | Gemini 3.6 Flash (Medium) | `agy` | Fast, cheap visual drafts; UI/UX surface iteration | Not for system structure — every draft needs architect approval |
| reviewer | Claude Opus 5 | `claude` | Same judgment as architect, held in reserve for a single final gate | Idle between gates; never the day-to-day reviewer |
| fallback | Gemini 3.6 Flash (Medium) | `agy` | Cheap/fast continuity when primaries hit rate/session limits | Not the default quality tier — finish interrupted work only |

## Default routing

- Design / ambiguous / high-risk → **architect**
- Hard implement / debug / verify / integrate → **executor**
- Raster image generate/edit → **executor** via Codex `$imagegen` (if brief ambiguous, coordinator asks user first)
- Small ticket / map / research / code prototype → **thrifty**
- UI/UX surface, visual draft → **ui** (architect approves)
- Final pre-merge gate → **reviewer**
- Idea research / brainstorm / find a niche → **debate driver** (`orca-debate.sh`)
- Session/rate limit on primary → **fallback**

## Debate lenses

The idea-debate mode (`orca-debate.sh`) seats one debater per provider, each arguing a different
lens so the four proposals/critiques stay genuinely adversarial instead of converging early:

| Provider | Lens | Why this model fits the lens |
|----------|------|-------------------------------|
| Claude | Principle & risk | Same long-horizon coherence and high-stakes judgment that makes it the architect/reviewer choice — applied here to failure modes and regulatory exposure. |
| Codex | Feasibility | Terminal/tool-loop execution experience grounds it in build cost and the shortest credible shippable slice, not just the idea in the abstract. |
| Grok | Contrarian & market | Fast, cheap, wide research reach makes it the natural angle-sweeper — surfaces prior art and takes the position nobody else argues. |
| Gemini | Demand & user | Cheap, fast iteration on user-visible surfaces (its `ui`/`fallback` day job) translates into a lens fixated on jobs-to-be-done and concrete usage evidence. |

## Patterns

```text
architect(plan) → executor|thrifty(impl) → architect(review-only)
image brief clear → executor ($imagegen)
image brief ambiguous → ask user → executor ($imagegen)
thrifty → (blocked) → executor → (design risk) → architect
ui(draft) → architect(approve) → ui(implement) → architect(review)
idea debate: propose → critique (anonymized) → converge → decide
any primary limit → fallback (agy Gemini 3.6 Flash Medium)
```

## Pricing notes (order of magnitude)

| Model | Typical use |
|-------|-------------|
| Opus 5 | Expensive quality lane (architect, reviewer) |
| GPT-5.6 Sol | Daily driver execution |
| Grok 4.5 | High throughput / cost efficiency |
| Gemini 3.6 Flash Medium | Cheap surface drafts (ui) and limit safety net (fallback) |
