# EVAL.md — llm-play autoresearch gate (domain program)

One screen. Agents read this before touching the llm-play surface.
Design + rationale: [autoresearch-llm-play.md](autoresearch-llm-play.md).

## Command

```
make eval IDEA=<idea_id>       # screen tier — every candidate change
make eval IDEA=<x> CONFIRM=1   # confirm tier — required before promote (5x walk budget)
make eval-pin-baseline         # promote-time only: re-measure + pin baseline.ref
```

Writes `runs/<utc>-<idea>/scorecard.json` (schema v0) and prints
`primary=<v> floors=pass|fail decision=keep|discard|inconclusive`.

Exit codes: `0` ran (decision may be discard) · `2` missing assets (ROM /
fixtures — regenerate, harness NOT broken) · `1` harness broken (canary
regressed / referee red).

## Primary (hero metric)

**`max_knock`** — latched knock % from the scripted turbo walk (Phase 1;
chain encoder comes with buzz/sunrise latching, see plan doc). Higher is
better. Live ceiling is knock=80 (bot cannot trigger sleep→knock);
`--campaign-fixtures` is **banned in eval** — it seats past the ceiling and
voids "the harness still walks".

## Hard floors (any fail ⇒ discard, even if primary improved)

| Floor | Check |
|-------|-------|
| `harness_canary` | Fixture gates score their `baseline.ref` pins (bedroom→tg, pokey_done→pokey, pre_knock_bed→knock) AND the scripted walk reaches the pinned latches |
| `referee_green` | `tests/test_knock_complete.nim` + `tests/test_eval_scorecard.nim` exit 0 |

Deferred (need instrumentation first — see plan doc): `no_softlock`,
`legit_play`, `readiness`.

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
