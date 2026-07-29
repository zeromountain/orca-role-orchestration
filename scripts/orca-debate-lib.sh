#!/usr/bin/env bash
# Pure helpers for the multi-model idea debate.
# Sourced only — do not execute. No set -e here (callers own shell options).
# Round prompt text lives here (single source); roles.yaml only documents the flow.

DEBATERS_DEFAULT="claude,codex,grok,gemini"

debate_role_key()   { printf 'debater_%s\n' "$1"; }
debate_short_name() { printf '%s\n' "${1#debater_}"; }

debate_slugify() {
  python3 - "$1" <<'PY'
import re, sys
text = sys.argv[1].strip().lower()
slug = re.sub(r'[^a-z0-9가-힣]+', '-', text).strip('-')[:48].strip('-')
print(slug or "debate")
PY
}

debate_label_map_create() {
  # $1=map_path $2=csv shorts. Creates once; later calls return the existing map.
  python3 - "$1" "$2" <<'PY'
import json, os, sys
path, names = sys.argv[1:3]
if os.path.exists(path):
    sys.stdout.write(open(path).read())
    raise SystemExit(0)
labels = "ABCDEFGH"
mapping = {}
for i, name in enumerate([n for n in names.split(",") if n.strip()]):
    mapping[name.strip()] = labels[i]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(mapping, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(json.dumps(mapping, ensure_ascii=False))
PY
}

debate_label_of() {
  # $1=map_path $2=short → label (empty if unknown)
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

debate_anonymize() {
  # $1=map_path $2=src_dir $3=dst_dir $4=prefix(proposal|critique)
  # Copies <src>/<short>.md → <dst>/<prefix>-<LABEL>.md, dropping H1 lines that
  # would identify the author. Missing sources are skipped (forfeits).
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, pathlib, sys
map_path, src, dst, prefix = sys.argv[1:5]
try:
    mapping = json.load(open(map_path))
except Exception as e:
    print(f"debate_anonymize: cannot read label map {map_path}: {e}", file=sys.stderr)
    sys.exit(1)
dst_p = pathlib.Path(dst)
dst_p.mkdir(parents=True, exist_ok=True)
written = []
for short, label in sorted(mapping.items(), key=lambda kv: kv[1]):
    source = pathlib.Path(src) / f"{short}.md"
    if not source.is_file() or not source.read_text().strip():
        continue
    body = "\n".join(
        line for line in source.read_text().splitlines() if not line.startswith("# ")
    ).strip("\n")
    out = dst_p / f"{prefix}-{label}.md"
    out.write_text(f"# {prefix.capitalize()} {label}\n\n{body}\n")
    written.append(out.name)
print("\n".join(written))
PY
}

debate_required_headings() {
  # $1=phase → one required substring per line
  case "$1" in
    propose)
      printf '%s\n' '## Prior art' '## Proposals' 'Weakest link:' '## Directions I deliberately rejected'
      ;;
    critique)
      printf '%s\n' '## Verdict per proposal' 'Verdict:' '## Ranking' '## Merged proposals'
      ;;
    converge)
      printf '%s\n' '## Differentiating axes' '## Niche candidates' 'Kill condition:' '## Dissent'
      ;;
    *) return 1 ;;
  esac
}

debate_lint() {
  # $1=file $2=phase. Prints each missing heading to stderr; exit 1 if any missing.
  local file="$1" phase="$2" missing=0 heading headings
  if [[ ! -s "$file" ]]; then
    echo "missing or empty: $file" >&2
    return 1
  fi
  # Capture into a variable and test the result directly in the `if`, rather
  # than `local headings="$(...)"` — combining `local` with an assignment
  # collapses the command substitution's exit status into `local`'s own
  # (always 0), which would silently re-introduce the fail-open bug this
  # guards against. An unrecognized phase must fail closed, matching
  # debate_spec's handling of the same bad input.
  if ! headings="$(debate_required_headings "$phase")"; then
    echo "unknown phase: $phase" >&2
    return 1
  fi
  while IFS= read -r heading; do
    if ! grep -Fq "$heading" "$file"; then
      echo "missing heading [$heading] in $file" >&2
      missing=1
    fi
  done <<EOF
$headings
EOF
  return "$missing"
}

debate_manifest_append() {
  # $1=manifest $2=short $3=task_id $4=status $5=flags
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, os, sys
path, short, task_id, status, flags = sys.argv[1:6]
rows = []
if os.path.exists(path):
    try:
        rows = json.load(open(path))
    except Exception:
        rows = []
rows.append({"debater": short, "taskId": task_id, "status": status, "flags": flags})
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(rows, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

debate_common_rules() {
  # $1=out_file
  cat <<EOF
HARD RULES
- Write your answer ONLY to this file: $1
  Create it if it does not exist. Overwrite it if it does.
- Never create or edit any other file. Never run git commit, git add, or any
  command that changes repository state. You are a discussant, not an implementer.
- Use EXACTLY the headings given below, in this order. A missing heading makes
  your contribution unusable to the other participants.
- Tag every factual claim with [출처: URL | 제품명 | 미검증]. Never invent a
  source — 미검증 is an honest and expected answer.
- Do NOT name your own model, provider, or analytical lens anywhere in the file
  body. Contributions circulate anonymously.
- When finished, send worker_done once, then stay open and idle. Do not close
  this terminal.
EOF
}

debate_spec() {
  # $1=phase $2=short $3=debate_dir $4=round $5=out_file $6=own_label $7=topic_file
  local phase="$1" short="$2" dir="$3" round="$4" out="$5" own="$6" topic_file="$7"
  local topic
  topic="$(cat "$topic_file" 2>/dev/null || echo "(topic file missing)")"

  case "$phase" in
    propose)
      cat <<EOF
IDEA DEBATE — ROUND $round of 3: PROPOSE

TOPIC
$topic

You are one of four participants, each on a different model with a different
analytical lens. In this round you cannot see the others. Research first, then
propose. Aim for proposals the other three would NOT have written.

$(debate_common_rules "$out")

REQUIRED STRUCTURE

# R$round proposal

## Prior art
List 3-6 things that already exist in this space: what they do, how far they got,
and where they stopped. One line each, every line tagged with a source.

## Proposals
Give 2-3. For each, use this exact shape:

### P1. <one-line name>
- Core hypothesis:
- Target user / JTBD:
- Why now:
- Differentiating axis: (what is actually different from the prior art above)
- Weakest link: (the strongest argument against your OWN proposal — required,
  and it must be a real objection, not a formality)
- Evidence: [출처: …]

## Directions I deliberately rejected
What you considered and dropped, and why. At least two.
EOF
      ;;
    critique)
      cat <<EOF
IDEA DEBATE — ROUND $round of 3: CRITIQUE

TOPIC
$topic

The other participants' round-1 proposals are on disk, anonymized. Read every
file matching:
  $dir/round-2/proposal-*.md

Proposal $own is your own — skip it in the per-proposal section below, but you
may still retract it at the end. You do not know who wrote the others, and you
must not guess or speculate about authorship.

Attack claims tagged [출처: 미검증] first — unsupported claims are the cheapest
thing to be wrong about.

$(debate_common_rules "$out")

REQUIRED STRUCTURE

# R$round critique

## Verdict per proposal
One block per proposal EXCEPT your own:

### Proposal <label>
- Fatal flaw: (at least one; if you genuinely believe there is none, you must
  justify that claim — "none" alone is not accepted)
- Unverified claims attacked:
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
Anything in your own proposal you no longer defend, and why. "None" is allowed
here only if you say what would have changed your mind.
EOF
      ;;
    converge)
      cat <<EOF
IDEA DEBATE — ROUND $round of 3: CONVERGE ON A NICHE

TOPIC
$topic

Everyone's round-2 critiques are on disk, anonymized. Read every file matching:
  $dir/round-3/critique-*.md
Your own round-1 proposals are at:
  $dir/round-1/$short.md

Your job now is to NARROW. A niche is a deliberately small target that
incumbents cannot or will not chase — not a smaller version of a big market.
Picking a broad, safe direction is a failure of this round.

$(debate_common_rules "$out")

REQUIRED STRUCTURE

# R$round niche convergence

## Differentiating axes
2-3 axes. For each: why this axis separates a defensible niche from a crowded market.

## Niche candidates
1-2, ranked. For each:

### N1. <name>
- One-sentence definition:
- Who I am explicitly giving up:
- Why this is a niche: (the structural reason incumbents cannot or will not do it)
- First validation experiment: (runnable in 1-2 weeks; success and failure
  stated as a number, not an adjective)
- Kill condition: (what fact would make you abandon this)
- Largest remaining uncertainty:

## Dissent
Candidates from the critiques that you do NOT support, and why. This section
must not be empty — if you support everything, say what you would sacrifice first.
EOF
      ;;
    *)
      echo "unknown phase: $phase" >&2
      return 1
      ;;
  esac
}
