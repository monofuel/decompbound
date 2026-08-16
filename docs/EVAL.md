# EVAL.md — llm-play autoresearch gate (domain program)

One screen. Agents read this before touching the llm-play surface.
Design + rationale: [autoresearch-llm-play.md](autoresearch-llm-play.md).

## Command

```
make eval IDEA=<idea_id>       # screen tier — every candidate change
make eval IDEA=<x> CONFIRM=1   # confirm tier — required before promote (5x walk budget)
make eval-pin-baseline         # promote-time only: re-measure + pin baseline.ref
make eval-report               # regenerate runs/index.html (hero series + table)
```

Writes `runs/<utc>-<idea>/scorecard.json` (schema v0) and prints
`primary=<v> floors=pass|fail decision=keep|discard|inconclusive`.

Exit codes: `0` ran (decision may be discard) · `2` missing assets (ROM /
fixtures — regenerate, harness NOT broken) · `1` harness broken (canary
regressed / referee red).

## Primary (hero metric)

**`chain_progress`** — the chain encoder over the story spine:
`100 × consecutively-complete gates + frontier gate %`, computed from the
walk's latched maxima. A gate is complete at its **live ceiling** — the
honest bot-reachable top, not the scorer max:

| gate | tg | pokey | knock | buzzbuzz | sunrise | frank | giant | captain | fourside | magicant | giygas |
|------|---:|------:|------:|---------:|--------:|------:|------:|--------:|---------:|---------:|-------:|
| live ceiling | 100 | 100 | **80** | 90 | 90 | **90** | 100 | 100 | 100 | **98** | **80** |

frank=90: 100 is the Frank-defeated flag — a real battle, blocked on the
battle-entry track like every other fight.

knock=80: bot cannot trigger sleep→knock (needs prologue-night capture).
magicant=98 / giygas=80: scorer soft caps await flag RE. A run that reads
"capped at N, blocked on X" every time is the ceiling made visible — that is
the point. `--campaign-fixtures` is **banned in eval** — it seats past
ceilings and voids "the harness still walks".

## Hard floors (any fail ⇒ discard, even if primary improved)

| Floor | Check |
|-------|-------|
| `harness_canary` | Fixture gates score their `baseline.ref` pins (bedroom→tg, pokey_done→pokey, pre_knock_bed→knock) AND the scripted walk reaches the pinned latches |
| `referee_green` | `tests/e2e_knock_complete.nim` + `tests/test_eval_scorecard.nim` exit 0 |
| `primary_ratchet` | Chain primary ≥ the champion primary computed from `baseline.ref`'s pinned walk — the hero number never regresses past promote |

Deferred (need instrumentation first — see plan doc): `no_softlock`,
`legit_play`, `readiness`.

## Timeouts are frame-based by construction (sim-time audit, 2026-08-16)

The Lua sandbox exposes `frame()` and no wall clock (`os` is nil'd), so every
skill constant (trail recover/retreat, A-pulse periods, retrace hold) counts
FRAMES and scales correctly under Turbo's uncapped fps — the wow-style
"6 seconds fired in 0.6s at 10x" bug class cannot occur in the reflex layer.
The only wall-clock users are the pacing loop (`getMonoTime`, real-time by
design) and LLM latency. Keep it that way: new skill timeouts count frames.

## Sacred surfaces (experiment agents never edit)

`compare.nim`, `tests/`, opcode table (standing law, AGENTS.md) **plus, for
llm-play lanes:** `src/tools/story_percents.nim`, `src/tools/touch_grass.nim`
percent functions, `src/tools/run_eval.nim`, `src/tools/eval_scorecard.nim`,
`baseline.ref`. The conductor RE-updates ladders; a lane that edits the
scorer to move a number gets discarded on sight.

## Candidate surface (what lanes MAY edit)

Policy Lua / seed policies, skill library (`touch_grass.nim` skill strings),
prompts/objectives in `llm_ai.nim`, nav layer, harness knobs. One idea = one
branch/worktree (`exp/<idea_id>`); never experiment on the live checkout.

## Deps (user-local, never committed)

ROM at `bin/Earthbound (U) [!].smc`; fixtures
`bin/states/llm/{bedroom,pokey_done,pre_knock_bed}.state` (regenerate:
`make play` capture or `llm_capture_fixture`, docs/llm-sequence.md).

## Copyright

Scorecards are token-shaped numbers/ids only — the writer rejects prose
(`eval_scorecard.nim` allowlist). `runs/*/logs/` is gitignored. No dialogue,
screenshots, or state bytes in `runs/`, ever.

## Promote

Merging a policy/skill change to master (or updating `baseline.ref`)
requires a **confirm-tier** scorecard + conductor approval. Failed runs stay
in `runs/` — history is the product.
