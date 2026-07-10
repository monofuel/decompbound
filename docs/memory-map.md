# EarthBound memory map — a living registry

**Status:** ongoing project. Seed entries below; grow as RE lands.
**Updated:** 2026-07-09.

## Why this exists

The llm-play plan is to build **reusable Lua functions that permanently solve
whole chunks of the game** (navigation, dialog-reading, menu-handling) so a model
like qwen plays at the **story level** — read the dialog, decide how to advance —
instead of mashing buttons or OCR-ing screenshots. EarthBound is very long; only
robust primitives scale.

Those primitives all read game state from memory. This file is the **single source
of truth for memory locations** so every tool (and qwen's prompt) references one
place instead of re-deriving addresses from scattered probe comments.

**Enabler:** the Lua sandbox must have **full-bus read access**. Today `mem.read`
is WRAM-only (`policy.nim`), but `cpu.read8(bus, addr)` already resolves the whole
24-bit space (ROM + WRAM). Expose read-only `snes.read` / `snes.readRange` so Lua
can read ROM tables (maps, dialog) directly. See
[`docs/pokey-percent.md`](pokey-percent.md) §3.

**Concrete example — dialog reading.** qwen must read story dialog to know how to
advance. `screen.text()` currently decodes it from the BG tilemap; parsing the
active text out of **RAM** (the window/message buffer) is likely more robust. That
buffer's address is a prime early target for this registry.

## Confidence legend

`✅ verified` (traced writer / byte-exact) · `🟡 used` (relied on by a tool, depth
unconfirmed) · `❓ unpinned` (known to exist, address/bit not nailed down).

## WRAM ($7E/$7F)

| Addr | Size | What | Conf | Notes / source |
|------|------|------|------|----------------|
| `$0B8E` | word × slots | Entity **world X** array (stride 2) | ✅ | Player = **slot 24** → `+0x30`. Writer traced `$C04E15` (`$0B8E,X`, X=0x30). `touch_grass.nim` |
| `$0BCA` | word × slots | Entity **world Y** array (stride 2) | ✅ | Same layout as X. Player = slot 24. |
| `$89CA` | word | **Sector ID** (per-area music/tileset/teleport) | ✅ | Set via `JSL $C3E74F`; setter at ROM `0x043573`. ⚠️ reads `0xFFFF` in some loaded states — confirm save-state restore. |
| `$9831` | word | **Money** ($) | 🟡 | `touch_grass.readU16`; used for progress signal. |
| `$8650` | byte | **First text/window slot header** — `0xFF` = free (no window open) | 🟡 | `advanceDialogue` gate. `$8958` = focus (unreliable alone). Message/dialog *buffer* still to pin (see "dialog reading" above). |
| `$988B..` | block | **Event flags** | 🟡 | Enter-only doesn't flip these; a "talked to Pokey" bit not yet found here. |
| `$4DBA` | byte | **in_battle** flag (`!=0` during battle) | 🟡 | `battleFixtureOk` in `touch_grass.nim`. |
| `~$2640` | word | **Live tilemap tile word**; the per-tile **passability ("pass") bit** lives here | ❓ | **Keystone for pathfinding — bit UNPINNED.** Pin empirically (walls vs. open ground). |
| `$0180/$0280/$02A0` | — | Battle-menu **font bases** (for on-screen text decode) | 🟡 | `screen.text()` path. |
| `$53` (SPC RAM) | byte | APU **timer0 target** shadow (FA shadow) | ✅ | Used by `recoverTimersAfterLoad`. Note: SPC address space, not S-CPU WRAM. |

## ROM (file offsets)

| Offset | What | Conf | Notes / source |
|--------|------|------|----------------|
| `0x100000` | **Tilemap pointer table** (4-byte entries → bank `$CF`) | ✅ | Byte-exact per `docs/decompilation.md`. |
| `0x101800` | **Tilemap data** (2-byte words) | ✅ | The map tiles A\* reads. |
| `0x043573` | **Sector setter** (writes `$89CA`) | ✅ | Takes pre-computed sector ID in `A`. |
| `$C3E012` | **Object-ID records** (8-byte) | 🟡 | `docs/decompilation.md`. |
| `0x03ED00` | Map / graphics load path | 🟡 | `docs/graphics.md`. |

## How to add an entry

1. **Verify, don't guess** — trace the writer (find the code that stores it) or
   diff WRAM across a known state change; don't infer from a plausible value (see
   memory `player-is-slot-24`).
2. Add a row with the confidence marker and *how* you verified it.
3. If a tool hardcodes the address, point its comment here so this stays canonical.

## References

- Map/sector RE detail: [`docs/decompilation.md`](decompilation.md)
- Navigation + read-access foundation: [`docs/pokey-percent.md`](pokey-percent.md)
- Savestate format (`ebSt`): [`docs/state-screenshots.md`](state-screenshots.md)
- Code constants: `src/tools/touch_grass.nim`, `src/tools/story_percents.nim`,
  `src/tools/probe_*.nim`
