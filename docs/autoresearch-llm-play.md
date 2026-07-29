# Bringing llm-play up to autoresearch status

**Status:** Phase 1 implemented (2026-07-28) — `make eval`, scorecard
writer, `baseline.ref`, `runs/`, `docs/EVAL.md`, `-d:noWindow` headless
gate. Phases 2–4 remain plan.
Cross-checked against code by a grok 4.5 review (2026-07-28,
`../decompbound_reports/autoresearch-llm-play-review.md`); factual
corrections folded in.
**Owner:** conductor. **Related:** [llm-plays.md](llm-plays.md),
[llm-sequence.md](llm-sequence.md), [llm-benchmarks.md](llm-benchmarks.md),
[roadmap.md](roadmap.md), and the generic contract in the autoresearch repo:
`~/Documents/Projects/Softmax/autoresearch/docs/project-shape.md` +
`scorecard.schema.v0.md` + `multi-axis-eval.md`.

## Why

The llm-play track has been floundering — not for lack of work, but because
nothing measures the work. Runs are one-offs; results live in chat and session
logs; there is no chart that answers "are we winning over time?" in five
seconds. That is the exact anti-pattern the autoresearch tenets name ("eval
only in chat", "scores buried in logs").

Autoresearch's adopt contract fixes this with three artifacts:

1. **One eval command** (`make eval`) that scores the current tree and fails
   loudly when the harness is broken.
2. **One scorecard file** per run (`runs/<utc>-<idea>/scorecard.json`,
   schema v0) — primary metric + hard floors + decision + reason codes.
3. **One hero graph** (progress series over runs, failures kept visible).

llm-play becomes autoresearch's first plugged-in vertical domain. The domain
(this repo) owns metric definitions, fixtures, and run data; autoresearch owns
the schema and, over time, shared report tooling.

## What we already have (assets, not gaps)

| Asset | Where | Contract role |
|-------|-------|---------------|
| Sacred referee doctrine | AGENTS.md / roadmap.md: `compare.nim`, `tests/`, opcode table are conductor-only. **Policy extension here:** `story_percents.nim` + `touch_grass.nim` become sacred *for experiment agents* too (the conductor still RE-updates ladders) | Sacred harness — agents never edit the scorer |
| Story-percent ladder | `src/tools/story_percents.nim` — referee-checked per-gate ladders; `llm_ai` latches tg/pokey/knock (+ later gates); buzz/sunrise are **not latched yet** (final value only) | Hero metric raw material |
| Deterministic emulator + fixtures | `bin/states/llm/*.state` (user-local, **gitignored** — a required dep of eval, never repo content), `.tas` replay | Fixed slate / reproducible trials |
| Scripted pilot track | `--pilot scripted --mock` seeds. NB: `make llm-ai-scripted` is Scripted·**Theater** (window, 60fps, 20k frames) — eval invokes `llm_ai` itself with `--tempo turbo`, it does not shell the make target | Pinned baseline + harness canary |
| Tier system T0–T4 | llm-benchmarks.md Benchmark B | Scorecard dimension (never compare across tiers) |
| Alignment failure classes | llm-benchmarks.md Benchmark A (correct / over-comply / distort / refuse / frame-break) | Ready-made reason codes |
| Milestone reports | `bin/llm_reports/` (frame, pos, policy, commit hash) | Embryo of the scorecard — wrong shape, no history |
| Multi-axis sketch | autoresearch `multi-axis-eval.md` §decompbound | The gate design, already written |

## The gate design (decided defaults — tune later, don't bikeshed now)

Following multi-axis-eval.md: **filter floors first, then rank on one hero
metric.** A candidate = one change to the llm-play surface (policy Lua, skill
library, prompt, harness knob) on its own branch/worktree.

### Hero metric (primary_for_ranking)

**Latched max story % across the prologue chain within budget**, higher is
better.

**Phase 1 (honest today, no new instrumentation):** `primary = max_knock`
raw latch, with `domain_extra` carrying the raw `{tg, pokey, knock}` latches.
These three are the only gates `llm_ai` latches today.

**Phase 2 (after buzz/sunrise latching + frames-to-gate land):** the chain
encoder `100 * gates_complete + frontier_pct`, where `gates_complete` counts
only gates that hit their **honest live ceiling** — and those ceilings must
be written down explicitly, because they differ from the scorer maxima:

Current ladder truth (from `story_percents.nim` + `test_knock_complete.nim`,
2026-07-24 — several docs, including llm-sequence.md, still describe older
stub states): the **scorer** grades knock to **100** via the knock-complete
signature (`$99F2=$58`), and buzzbuzz/sunrise have partial ladders to **90**
(100 reserved for verified flags — Picky/Buzz join; day-phase). But the
**live bot path** caps at knock=80: the bot cannot trigger sleep→knock, and
`--campaign-fixtures` seats past it by loading `post_knock*.state` — a
product convenience that is **banned in eval** (it would void "the harness
still walks"). So knock's live ceiling is 80 and counts as complete there.
Wherever a ceiling sits, **that is fine** — a scorecard that reads "capped at
N, blocked on <flag RE / battle-entry abort>" every run makes the bound
visible instead of ambient.

### Hard floors (any fail → discard, even if the hero number improved)

**Phase 1 ships exactly two floors** (multi-axis-eval.md's own advice: start
with 1–2 hard filters):

| Floor | Check |
|-------|-------|
| `harness_canary` | Scripted seed (Turbo, **no campaign seats**) still reaches the pinned expected percents recorded in `baseline.ref` (measure the actual seed once to set them — do not hardcode from docs, which drift). If the *baseline* regresses, the candidate run is void — the harness broke, not the policy. |
| `referee_green` | A **named subset** of referee tests exits 0 (full `nimble test` is too heavy per screen run; list the subset in EVAL.md). |

**Deferred floors (Phase 2+, each needs new instrumentation — do not claim
them before the detector exists):**

| Floor | What's missing today |
|-------|----------------------|
| `no_softlock` | The derail/BRK-sink/NMI-mask detectors live in `play.nim`, not the `llm_ai` loop; `cpu.stopped` ending the run is only a weak proxy. Port or share the detectors first. |
| `legit_play` | Doctrine exists; no mechanical detector does. "Glitch vs legit" needs a nav-layer OOB check; "no coordinate spoon-feeding" is a *prompt* property, checked at review time, not a runtime metric. |
| `readiness` (level ≥ band) | The multi-axis-eval.md decompbound sketch calls for it; only relevant once battles enter the hero path (buzzbuzz+). Conscious gap until then. |

### Secondary panel (recorded, not ranked)

Frames-to-gate for each gate passed (speed), LLM calls used, alignment-class
event counts (refusals / over-compliance logged per Benchmark A — a run
truncated by a filter event is scored honestly with `fail_alignment_truncated`
context, not silently as a capability failure).

### Scaffolding tiers (naming: avoid the schema collision)

The scorecard schema's top-level `tier` field means **`screen | confirm`** —
nothing else. The T0–T4 scaffolding tiers from llm-benchmarks.md go in
`domain_extra.scaffold_tier`. Never dual-use the name.

The canary is **T4-class** (seed/mock-driven — human-demo tier), and Agent
candidate runs default to **T3** (today's skills + objectives setup). Those
are different lanes by design: the canary is a floor, not a point on the
candidate series. Cross-tier comparison is meaningless; the runs series is
per-scaffold-tier.

### Screen vs confirm

| Stage | What runs | Budget (initial; consts in the runner, revise with data) |
|-------|-----------|-------------------------------------------------|
| **screen** | **Segmented canary** (cheaper and less flaky than one long monolith): score known fixtures directly (`bedroom`→tg, outdoor→pokey ladder, `pre_knock_bed`→knock=80) plus one short scripted walk from `pokey_done` toward knock; then the candidate from the current frontier fixture, single seed | ~200k frames total, 0 LLM calls (scripted) or 30 calls (agent) |
| **confirm** | Full chain walked from `bedroom.state`, n≥3 for agent scaffold tiers (LLM sampling is the only nondeterminism) | 1M frames per run |

Screen keeps iteration fast; **promote (merging a policy/skill change to
master) requires a confirm-tier scorecard.** Scripted candidates are
deterministic → n=1 is honest; agent candidates need n≥3.
`decision` takes three values per the schema: `keep | discard |
inconclusive` (budget ran out, n too low, fixtures missing).

### Scorecard + storage

`runs/<utc>-<idea_id>/scorecard.json` per autoresearch schema v0, at the repo
root (committed — see hygiene below). `domain_extra` carries:
`scaffold_tier`, `pilot`, `tempo`, `gates` (per-gate latched pct + frames),
`llm_calls`, `alignment_events`, `harness_commit`.

**Copyright hygiene:** scorecards are asset-free by construction — percents,
frames, reason codes, commit hashes only. **No dialogue text, no screenshots,
no state paths' contents.** Enforcement is **in the writer, not in prose**:
the scorecard writer allowlists keys and rejects free-form strings that could
carry dialogue. `runs/**/logs/` is gitignored (agent transcripts contain
`screen.text()` — that's script content, banned); `links` entries are opaque
path strings into `decompbound_secret`, never file copies. The report
artifact is SVG/HTML rendered from JSON numbers — no gameplay stills.
`runs/` scorecards are therefore committable, which is the point: the
history *is* the product.

### Report

`make eval-report` regenerates a static `runs/index.html` (or SVG/PNG): hero
series over runs (discards plotted, marked), per-gate table, reason-code
filter. Prefer upstreaming the generator to autoresearch once it works here
(phase 3 of autoresearch's build plan); a local Nim tool that reads
scorecards is the honest start.

## Known blockers (real, must be in the plan)

1. **Turbo is not display-free.** `llm_ai` imports windy/glblit under
   `when isMainModule`, so any main-module build links X11 even headless —
   `make eval` cannot run on a display-less box/CI until the window deps are
   compile-time gated. This is a **prerequisite for the "re-runnable by a
   skeptic" claim**, not a parallel checkbox — Phase 1 sequences it
   explicitly (interim: eval runs where DISPLAY exists, or scores fixtures
   without a full turbo walk). (Known issue, llm-play-overhaul.md.)
2. **Ladder caps (three distinct facts, don't conflate).** (a) The *live bot*
   soft-ceiling is knock=80 — no bot-triggerable sleep→knock; campaign seats
   fake past it and are banned in eval. (b) The *scorer* already grades
   knock=100 (signature `$99F2=$58`) and buzz/sunrise to 90; their 100s
   await verified flags (Picky/Buzz join; day-phase — human captures).
   (c) Battle progress is separately blocked by the battle-entry headless
   abort (`$5D7C` phase-3 timeout, memory-map.md) and `winBattle`'s
   bootstrap-shortcut victory detection. The eval ships **before** all of
   these — it scores the frontier as-is and makes the blockers visible as a
   flat line with reason codes. (NB: llm-sequence.md still calls these
   ladders stubs; the code is ahead of that doc.)
3. **Runner output is human-oriented.** `llm_ai` reports latches as echo
   lines (`max_pokey=…`); there is no structured (JSON) exit payload. The
   eval runner needs one — scraping log lines is fragile.
4. **Fixture deps.** Eval requires the user ROM plus local gitignored
   fixtures (`bedroom`, `pokey_done`, `pre_knock_bed`, …). A clean clone
   cannot run it; the runner must presence-check fixtures and exit non-zero
   with a "missing asset, regenerate via llm_capture_fixture / play" message
   distinct from "harness broken".
5. **Cost shape.** Agent-tier confirm runs burn real wall-clock against Azem
   (vision ~138s/frame stays out of eval entirely). Screen tier is scripted
   or short-agent only.

## Phased plan

Phases align with autoresearch project-shape.md §Phased build, renumbered
for domain-side work (local report HTML before upstreaming is explicitly
allowed by the contract). Each phase is independently shippable and useful.

**Phase 1 — contract surface (no new RE):** `EVAL.md`, scorecard writer,
`make eval` screen tier, baseline pin. Deliverable: one command → one JSON.

**Phase 2 — history + report:** append-only `runs/`, the hero-series
generator, confirm tier + n-runs. Deliverable: the chart.

**Phase 3 — loop:** idea heap doc, worktree convention, discard/keep
discipline; wire the existing roadmap blockers in as heap rows with reason
codes. Deliverable: parallel lanes can work llm-play without stepping on
monofuel's checkout (shared-working-dir rule).

**Phase 4 — upstream:** move the generic validator/report bits to
autoresearch; llm-play stays the reference instance.

## TODO

### Phase 1 — `make eval` + scorecard (the contract)

Ordered: the X11 gate sits **before** the full turbo canary, not beside it.

- [x] Write `docs/EVAL.md` (domain program): hero metric definition (Phase-1
      primary = `max_knock`), the two floors + the named referee-test
      subset, scaffold tiers, budgets, promote rule, fixture deps (ROM +
      gitignored states + how to regenerate) — one screen, agents read it
      first.
- [x] `src/tools/eval_scorecard.nim`: types + writer for schema-v0
      `scorecard.json` (top-level `tier: screen|confirm`;
      `domain_extra.scaffold_tier` for T0–T4; **key allowlist enforced in
      the writer** — reject free-form strings that could carry dialogue).
      Unit test with synthetic data (no ROM needed)
      (`tests/test_eval_scorecard.nim`).
- [x] Structured run output from `llm_ai`: `--result-json PATH` writes
      latched percents + frames at run end — replaces scraping
      `max_pokey=…` echo lines.
- [x] Fixture presence check in the runner: missing ROM/fixtures → exit 2
      with a distinct "missing asset" message (≠ exit 1 "harness broken").
- [x] Measure the scripted seed's actual latched percents per gate (one run,
      explicit `--mock --tempo turbo`, **no `--campaign-fixtures`**) and pin
      them in `baseline.ref` (`make eval-pin-baseline`).
- [x] `src/tools/run_eval.nim`: screen tier — **segmented canary** (score
      known fixtures directly + one scripted turbo walk), invoking `llm_ai`
      with explicit flags (never shelling `make llm-ai-scripted`, which is
      Theater/20k); assert `baseline.ref`; emit scorecard; print
      `primary=<v> floors=pass|fail decision=keep|discard|inconclusive`;
      exit 1 on broken harness or incomplete scorecard.
- [x] `Makefile`: `make eval IDEA=<x>` (screen) and `make eval CONFIRM=1`
      targets (+ `make eval-pin-baseline`).
- [x] `baseline.ref` at repo root: git sha + canary expected percents; eval
      reads it, promote updates it deliberately.
- [x] Add `runs/` to the repo: scorecards committed, `runs/*/logs/`
      gitignored; README stub stating the asset-free rule.
- [x] Compile-time gate the windy/X11 deps in `llm_ai`: `-d:noWindow` drops
      windy/glblit entirely (forces headless); `run_eval` builds the walk
      with it — turbo now runs without libX11. Default build unchanged
      (windowed `make llm-ai` untouched). ⚠️ human-verify row added for the
      windowed smoke test (llm_ai window paths were touched).

### Phase 2 — history + hero graph

- [ ] Latch buzz/sunrise in the runner (today only tg/pokey/knock + later
      gates are latched; buzz/sunrise report finals only) and add
      frames-to-gate instrumentation → emit the `gates` map into
      `domain_extra`; switch primary to the chain encoder
      (`100 * gates_complete + frontier_pct`, live ceilings documented).
- [ ] Alignment-event logger — **new code, nothing exists yet**
      (llm-benchmarks.md lists it under "Missing for A"): classify
      refusal/over-compliance/frame-break events from agent transcripts into
      `alignment_events` counts + `fail_alignment_truncated` reason code.
      Agent-tier runs only; N/A for the scripted canary.
- [ ] Port/share the softlock detectors (derail/BRK-sink/NMI-mask live in
      `play.nim` only) into the `llm_ai` loop → enable the `no_softlock`
      floor; add the nav OOB check → enable `legit_play`.
- [ ] `src/tools/eval_report.nim`: read all `runs/*/scorecard.json` → static
      `runs/index.html` with hero series (keeps + discards plotted),
      per-gate table, reason-code column. Numbers-only SVG/HTML; no
      gameplay stills.
- [ ] `make eval-report` target; regenerate on demand, artifact committed.
- [ ] Confirm tier: full chain from `bedroom.state`, n≥3 for agent scaffold
      tiers, aggregate scorecard (median primary, worst-case floors).
      Requires the X11 gate + real Azem wall-clock — budget it.
- [ ] Backfill baseline scorecards (scripted canary at T4; one Agent T3 run)
      so the chart starts with today's truth.

### Phase 3 — loop discipline

- [ ] `docs/llm-play-heap.md`: idea heap with class tags (nav / battle /
      prompt / memory / harness), each row = one branch-sized bet; seed it
      from the known blockers (knock flag RE, battle-entry abort, winBattle
      hardening, indoor landmarks, vision plumbing).
- [ ] Worktree convention for llm-play lanes (`exp/<idea_id>`), documented in
      EVAL.md — no experiments on monofuel's live checkout.
- [ ] Graveyard section in the heap doc: discarded ideas keep their scorecard
      link + reason code.
- [ ] Promote rule enforced socially: baseline.ref / master policy changes
      only from confirm-tier scorecards, conductor-approved.

### Phase 4 — upstream to autoresearch

- [ ] Split schema validation + series plotting into a reusable tool; PR it
      to the autoresearch repo; llm-play consumes it.
- [ ] Add an llm-play row to autoresearch `docs/learnings/README.md` with
      "what it taught" once the first month of runs exists.
- (pointer, not a decompbound task) A second domain — a Softmax game week —
  adopting the same tooling is what proves the schema isn't cosplay; that's
  autoresearch's phase 5 and lives there.

## Anti-patterns to refuse (from the autoresearch docs, instantiated here)

- Scoring pure speed: "fast to pokey" by fleeing every battle is the classic
  skip-grind confounder — level/readiness floors exist for exactly this once
  battles are in scope.
- Letting an agent edit `story_percents.nim` to make a number move — referee
  is sacred, full stop.
- Deleting failed runs from `runs/` — discards stay on the chart.
- Comparing T0 numbers to T3 numbers in one series.
- A beautiful dashboard with no scorecard files behind it.
