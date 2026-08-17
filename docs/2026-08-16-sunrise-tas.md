# 2026-08-16 sunrise TAS — bedroom → after Pokey's house (day)

**Human-verified 2026-08-16 — entire replay watched, confirmed accurate.**
`make play-tas` matches the manual run: bedroom (Fast text) through meteor
night, crater, Buzz Buzz, leaving Pokey's house at sunrise. No `TAS desync`.
Replay watch was session `20260816-224842` (same start state, no new `.tas`).
This is the first confirmed cadence-emu movie.

First human session on the **cadence emu** recorder. Loaded the Fast-text
bedroom fixture. One TAS segment. F12s are bookmarks on that same movie
(no slot load, no reset, no PNG drop). Wall time ~13 min; last `chk` is
frame 46200 (~12.8 min at 60 fps) — the clock matches.

The earlier [Fast-text TAS](2026-08-16-fast-text-tas.md) went farther
(Frank) but its `.tas` is window-loop garbage. This file is the one to
replay.

## Session (local, never commit)

| | |
|--|--|
| **Dir** | `../decompbound_secret/sessions/20260816-223148/` |
| **Build** | `8e839afaeb+dirty` · `session_start` 2026-08-16T22:31:48 |
| **ROM hash** | `0xDC9BB451` |
| **How launched** | `--load-state-path bin/states/llm/bedroom.state` (Fast text) |
| **Header** | `cadence emu` · `apu_ticks 533` |

| Segment | TAS | Start state | Last chk | Deltas |
|--|--|--|--|--|
| Bedroom → sunrise | `20260816-223148.tas` | `20260816-223148_start.state` | 46200 @ (0x099A,0x01A0) | 2694 |

F12s also under `~/Pictures/Screenshots/` and `secret/screenstates/`.

| F12 | Beat |
|--|--|
| `earthbound_20260816-223352.png` | Bedroom, standing, meteor night (start seat) |
| `223513` | Living room — Pokey / Picky / King, leaving the house |
| `223656` | Night path (Ness Lv2) |
| `223935` | Meteor crater — Picky, Pokey already gone |
| `224058` | Crater, party of three |
| `224245` | Path back, party of three (Ness Lv3) |
| `224257` | Path by Pokey's house, party of three |
| `224434` | **Day, Ness solo, Sound Stone, south of Pokey's house** |

WRAM at last F12: tg=100, pokey=70, pokey_knock=80. Ness Lv3 45/45,
items ATM card / Cracked bat / Cookie / Cookie / Sound Stone. Money $20.

## Bot

```
make llm-ai-prologue
```

Replays this movie, writes `bin/states/llm/sunrise_morning.state`, then the
LLM/scripted policy takes the pad on day Onett.

## Next segment (Giant Step, etc.)

```
make play-cont
```

Loads the newest F12 (right now `earthbound_20260816-224434.png`). Close the
window when you stop — that writes an end screenstate so the next
`make play-cont` does not need another F12.

## Replay

```
make play-tas TAS=../decompbound_secret/sessions/20260816-223148/20260816-223148.tas
```

Headless:

```
nim r src/tools/replay.nim "bin/Earthbound (U) [!].smc" \
  ../decompbound_secret/sessions/20260816-223148/20260816-223148_start.state \
  ../decompbound_secret/sessions/20260816-223148/20260816-223148.tas
```
