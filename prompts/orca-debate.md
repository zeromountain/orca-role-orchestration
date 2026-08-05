---
description: Run a four-model idea debate (Claude, Codex, Grok, Gemini) to sharpen an idea into a niche direction
argument-hint: <topic>
---

Run a multi-model idea debate. Topic: the arguments to this command.

1. Confirm the scaffold exists (`.orca/orchestration/scripts/orca-debate.sh`). If it does not,
   run `/orca-install` first.
2. If the topic is one vague sentence, ask the user one clarifying question about what decision
   this debate needs to inform. Do not ask more than one — the debate itself is the exploration.
3. Run:

   ```bash
   .orca/orchestration/scripts/orca-debate.sh --topic "<topic>"
   ```

   Three rounds run automatically: propose → critique (anonymized) → converge. Four tabs open,
   stay open between rounds, and close when the driver exits.
4. When it finishes, read `transcript.md` at the printed path and write the decision document to
   the printed `docs/ideas/…` path with these sections:
   - `## Decision` — the chosen niche, its kill condition, the first validation experiment
   - `## Runner-up` — the strongest rejected candidate and why it lost
   - `## Dissent` — round-3 positions this decision does not resolve

   Never drop a dissent to make the decision look cleaner.
5. Report the niche, its kill condition, and the first experiment to the user in a few lines.

Pass `--judge architect` instead of writing the document yourself when the user wants an
independent verdict. Pass `--debaters claude,codex,grok` when a provider is rate-limited.
