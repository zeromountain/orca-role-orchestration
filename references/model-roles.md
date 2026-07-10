# Model role strengths (routing background)

Research snapshot used to design the four Orca roles.

| Role | Model | CLI | Strengths | Weaknesses |
|------|-------|-----|-----------|------------|
| architect | Claude Opus 4.8 | `claude` | Judgment, honesty, long-horizon agents, high-stakes review, enterprise workflows | Higher token use; not ideal for bulk low-risk grind |
| executor | GPT-5.6 Sol | `codex` | Collaborative execution, persistence, terminal/tool loops, knowledge work, close the loop | Can over-engineer open-ended architecture; weaker pure taste/judgment vs Opus |
| thrifty | Grok 4.5 | `grok` | Speed, cost, codebase navigation, multi-file engineering, prototypes, Office artifacts | Less “taste” for full-delegation design/writing |
| fallback | Gemini 3.5 Flash (Medium) | `agy` | Cheap/fast continuity when primaries hit rate/session limits | Not the default quality tier — finish interrupted work only |

## Default routing

- Design / ambiguous / high-risk → **architect**
- Hard implement / debug / verify / integrate → **executor**
- Small ticket / map / research / prototype → **thrifty**
- Session/rate limit on primary → **fallback**

## Patterns

```text
architect(plan) → executor|thrifty(impl) → architect(review-only)
thrifty → (blocked) → executor → (design risk) → architect
any primary limit → fallback (agy Gemini 3.5 Flash Medium)
```

## Pricing notes (order of magnitude)

| Model | Typical use |
|-------|-------------|
| Opus 4.8 | Expensive quality lane |
| GPT-5.6 Sol | Daily driver execution |
| Grok 4.5 | High throughput / cost efficiency |
| Gemini 3.5 Flash Medium | Limit safety net only |
