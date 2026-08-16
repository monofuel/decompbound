# EarthBound campaign segments — the beat-the-game program

The run is divided into SEGMENTS. Each segment has a start fixture, a goal
expressed in story-percent gates, and ONE mechanical verify command. A
segment is DONE when its verify command passes headless — human eyes are
never the referee. A bug reported from watching a run becomes a headless
repro + regression check before any watched run restarts (one redeploy max).

Rules for every segment agent:
- No cheats: policies press buttons only (`mem.write` no longer exists in
  the sandbox). No `--campaign-fixtures` inside a segment; fixtures are
  segment STARTS only. Legit pathfinding, no glitches.
- The referee is sacred: `story_percents.nim`, `touch_grass.nim` percent
  functions, `run_eval.nim`, `eval_scorecard.nim`, tests.
- Improve the bot (seed policies, skills, prompts, nav) until the verify
  command passes; report evidence (actual command output), not claims.

## Verify harness

```
nim c -d:release -d:noWindow -o:bin/seg_walker src/tools/llm_ai.nim
bin/seg_walker --mock --pilot scripted --tempo turbo --headless --speed 0 \
  --frames <N> --load-state-path <fixture> --result-json /tmp/seg.json "<ROM>"
# then assert gates in /tmp/seg.json "max" versus the segment goal
```

## Segment table (live ceilings from docs/EVAL.md)

| # | Segment | Start fixture (bin/states/llm/) | Goal (result-json max) | Frames | Status |
|---|---------|--------------------------------|------------------------|-------:|--------|
| S1 | Prologue: bedroom → Pokey → home → Mom → bed | bedroom.state | tg=100, pokey=100, knock=80 | 100k | seed exists; re-verify after 2026-08-16 no-cheat rework |
| S2 | Buzz Buzz + sunrise | post_knock_outdoor.state | buzzbuzz≥80, sunrise≥50 | 150k | BLOCKED on battle-entry abort (own track below) |
| S3 | Day-1 Frank + Giant Step | frank_downtown.state | frank=90, giant≥50 | 150k | frank 100 = Frank FIGHT flag (battle-blocked, track B); 90 is the live ceiling |
| S4 | Captain Strong / leave Onett | captain_approach.state | captain≥60 | 120k | AgentCaptain seed exists |
| S5 | Twoson / Paula approach | leave_onett_walkable.state | paula_rescue≥50 or winters≥50 | 200k | AgentPaula/Midgame seeds exist |
| S6 | Fourside deep | fourside60_walkable.state | fourside≥80 | 200k | needs Poo/party continuity (fo80 blend) |
| S7 | Late game soft | poo_soft98_walkable.state | magicant=98, giygas=80 | 200k | soft ceilings; flag RE pending |
| B | Battle-entry root cause | replay 20260709-234547 f=1857 repro | fresh contact entry promotes past $98A5=3 headless | — | style/context word writer hunt (docs/memory-map.md $5D7C row) |

Segment DONE ⇒ its verify goal moves into the eval chain encoder's expected
frontier; `make eval` keeps every earlier segment green forever (ratchet).

## Current blockers that segments must NOT paper over

- Battle entry aborts headless (track B). Segments needing battles (S2's
  Starman Jr, later required fights) stay blocked until B lands — no fixture
  seat-arounds; that is the shortcut ban.
- knock=80 ceiling (sleep flag) and magicant/giygas soft caps are HUMAN /
  RE gated; segments treat them as their honest tops.
