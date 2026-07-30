#!/usr/bin/env bash
# Pure helpers for the multi-model idea debate.
# Sourced only — do not execute. No set -e here (callers own shell options).
# Round prompt text lives here (single source); roles.yaml only documents the flow.

DEBATERS_DEFAULT="claude,codex,grok,gemini"

# Task 2: dead-man watchdog for `--persist` tabs. Generous relative to a
# single round (R1_TIMEOUT_MS in orca-debate.sh is 1800000 = 30 min — the
# longest one) while remaining far short of "hours" if a debate is
# abandoned. In practice this is a backstop, not the primary detector: the
# watchdog is an independent polling process (see
# orca-sweep-orphans.sh --watchdog) that notices the owning driver's death
# via `kill -0` within one poll interval (default 20s, see
# WATCHDOG_POLL_SECONDS_DEFAULT below), decoupled from how long any given
# round takes — the driver spends most of a round blocked waiting on a
# child process, so a "the owner refreshes its own heartbeat between doing
# other work" design would leave gaps as long as a round itself. Instead
# the watchdog refreshes the heartbeat on the owner's behalf, once per poll
# cycle, for as long as `kill -0 <owner pid>` keeps succeeding.
DEBATE_LOCK_TTL_SECONDS_DEFAULT=1800
WATCHDOG_POLL_SECONDS_DEFAULT=20

# Task 3 fix round 1: closes a TOCTOU race in orca-debate.sh's cross-slug
# concurrency refusal. Scanning "$LOCK_DIR/*.json" for another slug's live
# lock only helps if this driver's OWN lock already existed at scan time —
# but it does not (debate_watchdog_start writes it only after the scan
# passes), so two different-slug drivers started close together can each
# complete the scan, see nothing, and both proceed into ensure_terminal's
# shared role terminals. This is a real mutex, not per-slug bookkeeping: a
# single, well-known directory name (never one named after any slug) so
# that ANY two concurrent driver invocations — regardless of which slugs
# they are for — serialize through the exact same critical section
# (scan-other-slugs-then-register-mine, in orca-debate.sh). mkdir is atomic
# on a POSIX filesystem: exactly one concurrent caller's mkdir can succeed
# for a given path, which is what gives this mutual exclusion without
# flock(1) (unavailable on this repo's floor, bash 3.2 / macOS).
DEBATE_STARTUP_MUTEX_MAX_WAIT_SECONDS_DEFAULT=5
DEBATE_STARTUP_MUTEX_STALE_SECONDS_DEFAULT=2

debate_dir_age_seconds() {
  # $1=path -> age in whole seconds since the path's mtime, on stdout.
  # Nothing on stdout and exit 1 if the path does not exist / mtime cannot be
  # read. Used only to decide whether a held startup mutex is old enough to
  # be considered abandoned (see debate_startup_mutex_acquire) — never used
  # for the debate lock's own heartbeat/TTL (that stays lock_is_fresh, in
  # orca-roles-lib.sh, untouched).
  python3 - "$1" <<'PY'
import os, sys, time
try:
    mtime = os.path.getmtime(sys.argv[1])
except Exception:
    sys.exit(1)
print(int(time.time() - mtime))
PY
}

debate_startup_mutex_acquire() {
  # $1=locks_dir $2=owner_pid $3=(optional) max_wait_seconds
  #
  # Acquires the global mkdir-based startup mutex at
  # "$locks_dir/.starting.lock". Returns 0 (acquired) or 1 (gave up after
  # max_wait_seconds without acquiring — the caller must treat this as
  # "refuse to start," never as "assume clear," matching this codebase's
  # existing bias elsewhere: never treat an inability to determine
  # something as license to act.
  #
  # A holder that dies mid-critical-section (before calling
  # debate_startup_mutex_release) would otherwise deadlock EVERY future
  # debate start forever, so a stale claim is force-reclaimed — but only
  # when it is old enough that we are not simply racing a peer that just
  # mkdir'd (the DEBATE_STARTUP_MUTEX_STALE_SECONDS_DEFAULT guard below,
  # applied to BOTH branches immediately below). An alive or undeterminable
  # owner is always left alone — same "never treat can't-tell as gone" rule
  # as pid_alive() in orca-sweep-orphans.sh and lock_handle_claimed_elsewhere
  # in orca-roles-lib.sh (neither touched by this function):
  #   - pid file present, and its process is CONFIRMED dead (kill -0 fails):
  #     reclaim once old enough.
  #   - pid file ABSENT entirely: this is EITHER a peer whose mkdir just
  #     succeeded and has not yet reached its own `printf … > pid` two lines
  #     below (must NOT be stolen), OR the previous holder was killed
  #     (SIGKILL, OOM, host crash — not a normal exit, which the caller's own
  #     trap/cleanup already covers) in that exact gap, before ever writing a
  #     pid (found by direct reproduction: with no pid file EVER written,
  #     the check below used to require one before it would even consider
  #     staleness, so a directory in this state was NEVER reclaimed at any
  #     age — a silent, total, permanent block on every future debate start,
  #     for every slug, fixable only by a human manually removing a hidden
  #     directory the refusal message did not name). Age is what tells these
  #     two apart: the real gap between `mkdir` and the pid write is two
  #     adjacent bash builtins — sub-millisecond even under load — so
  #     DEBATE_STARTUP_MUTEX_STALE_SECONDS_DEFAULT (2s, the same threshold
  #     already used for the confirmed-dead-pid branch) is several orders of
  #     magnitude of margin: a pid-less directory this old is unambiguous
  #     evidence of the crash case, never the in-flight-peer case.
  local locks_dir="$1" owner_pid="$2"
  local max_wait="${3:-$DEBATE_STARTUP_MUTEX_MAX_WAIT_SECONDS_DEFAULT}"
  local mutex_dir="$locks_dir/.starting.lock"
  local poll_s="0.05"
  local max_iterations
  max_iterations="$(python3 -c "print(max(1, int(float('$max_wait') / $poll_s)))")"
  local i=0 held_pid age reclaim=0
  while true; do
    if mkdir "$mutex_dir" 2>/dev/null; then
      printf '%s\n' "$owner_pid" > "$mutex_dir/pid" 2>/dev/null || true
      return 0
    fi
    reclaim=0
    held_pid="$(cat "$mutex_dir/pid" 2>/dev/null || true)"
    age="$(debate_dir_age_seconds "$mutex_dir" 2>/dev/null || true)"
    if [[ -n "$age" ]] && [[ "$age" -ge "$DEBATE_STARTUP_MUTEX_STALE_SECONDS_DEFAULT" ]]; then
      if [[ -n "$held_pid" ]]; then
        # Pid recorded — only reclaim once it is CONFIRMED dead.
        ! kill -0 "$held_pid" 2>/dev/null && reclaim=1
      else
        # No pid recorded at all, and old enough that this can only be the
        # crash-before-writing-it case, never a peer still mid-mkdir.
        reclaim=1
      fi
    fi
    if [[ "$reclaim" -eq 1 ]]; then
      rm -rf "$mutex_dir" 2>/dev/null || true
      continue
    fi
    i=$((i + 1))
    if [[ "$i" -ge "$max_iterations" ]]; then
      return 1
    fi
    sleep "$poll_s"
  done
}

debate_startup_mutex_release() {
  # $1=locks_dir. Idempotent — safe to call whether or not this process
  # actually holds the mutex, and safe to call more than once (the EXIT trap
  # in orca-debate.sh and its own explicit release both call this; only one
  # of them will ever find something to remove).
  local locks_dir="$1"
  rm -rf "${locks_dir:?}/.starting.lock" 2>/dev/null || true
}

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

debate_label_map_ensure() {
  # $1=map_path $2=slug $3=csv shorts (this run's roster)
  #
  # Task 3: label-native anonymization. Ownership is deliberately narrow —
  # ONLY orca-debate.sh (the driver) ever calls this function, before round 1
  # starts, and passes the resulting path down to orca-debate-round.sh via
  # --label-map. orca-debate-round.sh (and every debater dispatch spec) only
  # ever READS this file (debate_label_of / debate_short_for_label below); it
  # never creates or rewrites it. This is what makes it possible for a fresh
  # subprocess (each round is a separate orca-debate-round.sh invocation) to
  # agree with the previous round's subprocess on what "Proposal C" means,
  # without any round script ever deciding label policy itself.
  #
  # Labels are SHUFFLED per debate (python's random, freshly seeded per
  # process from OS entropy — not the roster's CSV order), because the
  # roster's default order (DEBATERS_DEFAULT above) is a public constant in
  # this very file: a positional A=first-in-roster assignment is derivable
  # from source alone regardless of where the map file lives.
  #
  # Creates fresh if absent. If present AND its recorded "roster" (as a set,
  # order-independent) matches the given roster, reuses the existing
  # mapping unchanged — labels must stay stable across round 1→2→3 of the
  # SAME driver invocation. If the roster differs (a re-run of the same slug
  # with a changed --debaters), rebuilds with a fresh shuffle for the new
  # roster and prints a loud warning to stderr — never silently reuses a
  # stale mapping, which would otherwise either drop a participant's
  # contribution (an old label with no current debater behind it) or leave a
  # newly-added participant with no label at all (a ghost). Rebuilding here
  # is safe specifically because orca-debate.sh wipes that slug's previous
  # round-*/transcript.md/manifest before calling this — if that wipe is
  # ever removed, this rebuild-on-mismatch would need to become a hard
  # refusal instead, since a rebuilt map could then mix with output written
  # under the old one.
  local path="$1" slug="$2" names="$3"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  python3 - "$path" "$slug" "$names" <<'PY'
import json, os, random, sys

path, slug, names_csv = sys.argv[1:4]
roster = [n.strip() for n in names_csv.split(",") if n.strip()]

existing = None
if os.path.exists(path):
    try:
        existing = json.load(open(path))
    except Exception:
        existing = None

if existing is not None and sorted(existing.get("roster") or []) == sorted(roster):
    sys.stdout.write(json.dumps(existing, ensure_ascii=False))
    sys.exit(0)

if existing is not None:
    old_roster = existing.get("roster") or []
    print(
        "debate_label_map_ensure: roster changed for slug '%s' (was: %s; now: %s) "
        "— rebuilding the label map with a fresh shuffle, NOT reusing the stale one"
        % (slug, ",".join(old_roster), ",".join(roster)),
        file=sys.stderr,
    )

letters = list("ABCDEFGH"[: len(roster)])
random.shuffle(letters)
mapping = dict(zip(roster, letters))
data = {"slug": slug, "roster": roster, "labels": mapping}

tmp_path = path + ".tmp." + str(os.getpid())
with open(tmp_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp_path, path)
print(json.dumps(data, ensure_ascii=False))
PY
}

debate_label_of() {
  # $1=map_path $2=short → label (empty if unknown, missing, or malformed)
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print((d.get("labels") or {}).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

debate_short_for_label() {
  # $1=map_path $2=label $3=expected_slug → short name, or empty if unknown,
  # missing, malformed, OR the map's own recorded "slug" does not match
  # $3. That last guard matters only for build_transcript: if a slug's label
  # map was later rebuilt (roster changed) after an OLDER debate directory's
  # round output was produced under the earlier mapping, reverse-lookups
  # through the now-current map would silently misattribute that older
  # content. Used only by the driver's transcript builder — never by a
  # debater's dispatch spec.
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, label, expected_slug = sys.argv[1:4]
try:
    d = json.load(open(path))
except Exception:
    print("")
    raise SystemExit(0)
if expected_slug and d.get("slug") != expected_slug:
    print("")
    raise SystemExit(0)
labels = d.get("labels") or {}
for short, lab in labels.items():
    if lab == label:
        print(short)
        raise SystemExit(0)
print("")
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
      local prev_round=$((round - 1))
      cat <<EOF
IDEA DEBATE — ROUND $round of 3: CRITIQUE

TOPIC
$topic

The other participants' round-$prev_round proposals are on disk, anonymized under
labels. Read every file matching:
  $dir/round-$prev_round/*.md

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
      local prev_round=$((round - 1))
      cat <<EOF
IDEA DEBATE — ROUND $round of 3: CONVERGE ON A NICHE

TOPIC
$topic

Everyone's round-$prev_round critiques are on disk, anonymized under labels. Read
every file matching:
  $dir/round-$prev_round/*.md
Your own round-1 proposal is at:
  $dir/round-1/$own.md

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

debate_watchdog_start() {
  # $1=here(scripts dir, for locating orca-sweep-orphans.sh)
  # $2=lock_file $3=slug $4=owner_pid $5=locks_dir $6=ttl_seconds
  # Writes the initial lock (lock_write, from orca-roles-lib.sh — must
  # already be sourced by the caller) and starts the watchdog daemon via
  # nohup, backgrounded. Prints the watchdog's own pid on stdout.
  local here="$1" lock_file="$2" slug="$3" owner_pid="$4" locks_dir="$5" ttl="$6"
  lock_write "$lock_file" "$owner_pid" "$slug" "$ttl"
  nohup "$here/orca-sweep-orphans.sh" --watchdog --slug "$slug" --owner-pid "$owner_pid" \
    --locks-dir "$locks_dir" >"${lock_file%.json}.watchdog.log" 2>&1 &
  printf '%s\n' "$!"
}

debate_watchdog_stop() {
  # $1=watchdog_pid_file $2=lock_file
  # Stops the watchdog (SIGTERM — its own trap exits without touching
  # anything, since a driver reaching this point is exiting deliberately,
  # whether or not it chooses to close tabs itself right after) and removes
  # the lock. Idempotent and safe to call even when nothing was ever
  # started (e.g. --dry-run never calls debate_watchdog_start, so both
  # files below are simply absent and every step here is a guarded no-op).
  local pid_file="$1" lock_file="$2" wpid
  if [[ -f "$pid_file" ]]; then
    wpid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null; then
      kill -TERM "$wpid" 2>/dev/null || true
      echo "debate_watchdog_stop: stopped watchdog pid=$wpid" >&2
    fi
    rm -f "$pid_file"
  fi
  lock_remove "$lock_file"
}
