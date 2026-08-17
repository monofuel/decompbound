# 2026-08-16 Fast-text TAS — title → Frank (loss)

Cold-boot new file after the aborted [slow-text bedroom run](2026-08-16-bedroom-tas.md).
Naming confirm is Steak / Rockin'. Text speed is **Fast**. This is the
teaching record.

Got through the meteor night, **Starman Jr**, sunrise, downtown, extra
prep before the sharks, and into Frank. **Frank won.** Two TAS segments
+ 19 F12 bookmarks (each F12 is also a restorable `ebSt` save).

`bin/states/llm/bedroom.state` is now this run's standing-bedroom F12
(`183333`). Old medium-text file kept as
`bin/states/llm/bedroom_medium.state` (gitignored, local only).

**This session's `.tas` is not a valid emu-frame movie.** Recorder stamped
window-loop time (turbo compresses many emu frames into one TAS frame).
Replay presses A before title is ready and never leaves boot. F12s are
the ground truth. Re-record is done: [sunrise TAS](2026-08-16-sunrise-tas.md)
(`20260816-223148`, cadence emu, bedroom → sun-up).

## Session (local, never commit)

| | |
|--|--|
| **Dir** | `../decompbound_secret/sessions/20260816-183136/` |
| **Build** | `8e839afaeb` · `session_start` 2026-08-16T18:31:36 |
| **ROM hash** | `0xDC9BB451` |
| **How launched** | cold-boot `make play` (no load-state) |

| Segment | TAS | Start state | Last frame | Deltas |
|--|--|--|--|--|
| Main (title → arcade) | `20260816-183136.tas` | `20260816-183136_start.state` | 163979 | 4361 |
| Short post-load | `20260816-185045.tas` | `20260816-185045_start.state` | 920 | 7 |

F12s also under `~/Pictures/Screenshots/` and `secret/screenstates/`.

| F12 | Beat |
|--|--|
| `earthbound_20260816-183146.png` | Title |
| `183226` / `183228` | Naming confirm (Steak / Rockin') |
| `183312` | House exterior, meteor night |
| `183323` | Bedroom, asleep |
| `183333` | Bedroom, standing — **Fast-text bedroom seat** |
| `183530` | Bedroom, at the door |
| `183742` | Night path, house in view |
| `183848` | First random fight (Ness 18 HP / 10 PP) |
| `184046` | Meteor crater (Pokey + Picky) |
| `184128` | Path, party of three after the crater |
| `184138` | **Starman Jr** (command menu, Ness 16/11) |
| `184258` | Path, party of three |
| `184321` | Minch living room |
| `184439` | Ness's house, daytime (sunrise) |
| `184619` | Downtown Onett (drugstore / burger shop) |
| `184621` | Onett town-hall sign |
| `184736` | Arcade interior |
| `185012` | Arcade, south machines — last bookmark |

## Human notes

Went mostly well. Wanted a Mom heal at the house before the hill; skipped
it because the climb was lucky (several easy snakes) and healing did not
feel needed. Extra items before the sharks. Got too aggressive into Frank
and died — more grinding next time.

## Fixture

Bedroom start for `make llm-ai` is Fast-text, extracted from
`earthbound_20260816-183333.png` on 2026-08-16. `game_start.state` is
still the old medium seed; `bedroom.state` exists so the Makefile will
not recopy it.

Replay the main movie from the session start state:

```
nim r src/tools/replay.nim "bin/Earthbound (U) [!].smc" \
  ../decompbound_secret/sessions/20260816-183136/20260816-183136_start.state \
  ../decompbound_secret/sessions/20260816-183136/20260816-183136.tas \
  --frames 163979
```
