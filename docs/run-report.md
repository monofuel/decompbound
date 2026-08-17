# Run report — TAS / bot-run diagnostic

Replay a recorded `.tas` + start state and print a markdown report:
dialogue, story-latch changes, battles, level-ups, inventory diffs,
room changes, deaths, money.

```
nim r src/tools/run_report.nim --session ../decompbound_secret/sessions/20260816-183136
nim r src/tools/run_report.nim <rom> <start.state> <log.tas> [--out bin/reports/x.md] [--frames N]
make run-report SESSION=../decompbound_secret/sessions/20260816-183136
```

One current F12 (no TAS replay):

```
make run-report LATEST=1
nim r src/tools/run_report.nim --latest-f12
nim r src/tools/run_report.nim --f12 ~/Pictures/Screenshots/earthbound_….png
```

`--session` uses the longest `.tas` in that dir (the main segment) and its
matching `_start.state`. Default `--frames` is the last input delta.
Default `--out` is `bin/reports/<tas-stem>.md`. `--bookmarks-only` skips
the TAS step and only samples `f12/*.png`. New movies have `cadence emu`
and replay 1:1. Pre-fix movies are refused unless `--legacy-stretch N`.

Identity referee: `nim r tests/e2e_tas_identity.nim` — start + TAS walk
must match pos, WRAM hash, and the full serialize blob on replay.

This is a sampler on the existing replay loop (`policy.stepOneFrame`,
no PPU draw). It does **not** hook the text-print routine
([text-log.md](text-log.md) stays tabled).

Fidelity rules (v2): rooms come from world-pos boxes + landmarks (sector
`$89CA` is `FFFF` on many F12s). Dialogue is the `$96C5` stream
(`getRecentDialogue`) even after the window closes — no tilemap dump.
Battle lines are menu + enemy names. Story keys latch to a running max
so indoor scorer bounce is not a beat. Level-ups require a prior
in-party level > 0.

`--session` also samples every `f12/*.png` (ebSt) as a **Bookmarks**
chapter. Movies recorded before the per-emu-frame tap (window-loop
timestamps) will sit on title — see [input-replay.md](input-replay.md).
Re-record; do not treat those `.tas` files as broken NMI.

## Copyright

The **tool** is ours. The **report body** is extracted game text
(dialogue, battle flavor, item names). Write only under `bin/reports/`
(`bin/*` is gitignored). The CLI refuses any other path. Never commit a
generated report. Tests use dummy strings (`aaa` / `bbb`), not game text.

## Bot runs

`llm_ai` does not write `.tas` yet. Same format as `play.nim` recording
is the follow-up; then this command grades bot sessions too.
See [input-replay.md](input-replay.md).
