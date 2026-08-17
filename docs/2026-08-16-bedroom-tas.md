# 2026-08-16 bedroom TAS — aborted (slow text)

Superseded by [2026-08-16 Fast-text TAS](2026-08-16-fast-text-tas.md)
(cold-boot new file, title → Onett arcade).

First human record from the same seat the llm-play bot uses
(`bin/states/llm/bedroom.state`). Stopped after **one fight**. Do **not**
mine this session as bot ground truth.

**Abort reason:** the bedroom fixture's text speed is **medium or slow**.
That is not acceptable for a teaching TAS or for the bot. Text speed is
chosen on the naming / file-setup screen, so this file cannot be patched
in place. Next run needs a **new** bedroom state cut from a Fast-text
file.

## Session (local, never commit)

| | |
|--|--|
| **Dir** | `../decompbound_secret/sessions/20260816-182409/` |
| **TAS** | `20260816-182409.tas` (1137 deltas, last frame 44033) |
| **Start** | `20260816-182409_start.state` (snapshot of the loaded bedroom fixture) |
| **Build** | `8e839afaeb` · `session_start` 2026-08-16T18:24:09 |
| **ROM hash** | `0xDC9BB451` |
| **How launched** | `nim r -d:release src/tools/play.nim --load-state-path bin/states/llm/bedroom.state "bin/Earthbound (U) [!].smc"` |

F12s (also under `~/Pictures/Screenshots/` and `secret/screenstates/`):

- `earthbound_20260816-182437.png` / `182438.png` — living room
- `earthbound_20260816-182531.png` — meteor crater
- `earthbound_20260816-182644.png` — house, talking to Mom
- `earthbound_20260816-182920.png` — night path with Picky

## Fixture problem

`bin/states/llm/bedroom.state` (seeded from `bin/states/game_start.state`
when missing) skipped the naming screens — and inherited whatever text
speed that file was created with. Felt like Medium or Slow in play.

A slow-text TAS is the wrong shape for the bot: dialogue advance becomes
the whole movie, and any later Fast-text fixture will not replay against
it.

## Next run

1. Cold-boot `make play` (no `--load-state-path`).
2. New file. Name the party. Set text speed **Fast**.
3. Reach Ness's bedroom. F12 or Ctrl+1.
4. Replace `bin/states/llm/bedroom.state` (and `game_start.state` if that
   is still the seed) with the Fast-text snapshot.
5. Restart the TAS from that seat. Same one-liner as above.

Human-verify row: **Remake bedroom.state with Fast text**.
