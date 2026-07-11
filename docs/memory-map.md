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
| `$8650` | byte | **First text/window slot header** — `0xFF` = free (no window open) | 🟡 | `advanceDialogue` gate. `$8958` = focus (unreliable alone). Slot 1 = `$8654` (NPC/scene dialogue). |
| `$96C5` | far ptr (24-bit) | **Live dialogue script cursor** into ROM (bank $C0-$CF → HiROM file offset) | ✅ | Advances as chars print. Decoded by `getDialogueText` (`text_decode.nim`): storage byte = ASCII+0x30; control `<0x20` (dispatch file `0x1890E`); `0x15/16/17` = dictionary-token calls via far-ptr tables `0x8CDED/0x8D1ED/0x8D5ED`. EB dialogue is **VWF** so VRAM tiles are pixel glyphs, not chars — the script stream is the only reliable read. Verified 2026-07-10 vs "[redacted dialogue]". |
| `$988B..` | block | **Event flags** | 🟡 | Enter-only doesn't flip these; a "talked to Pokey" bit not yet found here. |
| `$4DBA` | byte | **in_battle** flag (`1` during battle, `0` when it ends) | ✅ | `STA` file `0xD65A` / `STZ` `0xD1A8`. Victory = `$4DBA` 1→0. Gate: real battle also needs BG **mode 0** (`$2105`&7==0) — dead fixtures set the flag but not the mode. |
| `$5D60` | word | **Battle result / end code** — `$0078` on victory | 🟡 | Grok battle RE 2026-07-11; sustained on win. |
| `$4DC8` | struct×party | **Battle party structs** — stride `$5F`; HP at `+0x0A`, PP at `+0x0C` | 🟡 | For heal/defend logic. Grok battle RE 2026-07-11. |
| `$E000` | 64×64 bytes | **Live collision page** — one byte per 8px coarse tile; **blocked iff `(byte & 0xD0) != 0`** | ✅ | Read by `$C05F33` (`LDA $E000,X`, DBR=`$7E`); walk gate `AND #$00D0; BNE` at file `0x0029CC` before the `$0B8E,X` pos write. Index `((cy&0x3F)<<6)\|(cx&0x3F)`, `cx=(xAdj>>3)`, `cy=(yAdj>>3)`; adj offsets from ROM tables below. Page **wraps mod 64 tiles** (512×512px window); loader that fills it from ROM not yet pinned. Verified vs live movement 4/4 dirs (`probe_walkable.nim`, 2026-07-09). Onett bytes: `0x00` open, `0x80` solid, `0x01/0x03` pass. |
| `$2B6E` | word × slots | Entity **collision type** (stride 2; player outdoor = 5) | ✅ | Indexes the `$C42A1F/...` offset + hitbox tables in `$C05F33`. |
| `$0180/$0280/$02A0` | — | Battle-menu **font bases** (for on-screen text decode) | 🟡 | `screen.text()` path. |
| `$53` (SPC RAM) | byte | ⚠️ **NOT an FA shadow** — drifting driver variable (`0x10→0x24` over one song) | ✅ | Restoring T0 target from it halved music tempo on v1 loads (2026-07-09). The EB driver's real T0 target is a **constant `$10`**; `recoverTimersAfterLoad` uses that. SPC address space, not S-CPU WRAM. |

## ROM (file offsets)

| Offset | What | Conf | Notes / source |
|--------|------|------|----------------|
| `0x100000` | **Tilemap pointer table** (4-byte entries → bank `$CF`) | ✅ | Byte-exact per `docs/decompilation.md`. |
| `0x101800` | **Tilemap data** (2-byte words) | ✅ | The map tiles A\* reads. |
| `0x043573` | **Sector setter** (writes `$89CA`) | ✅ | Takes pre-computed sector ID in `A`. |
| `0x005F33` | **Collision probe `$C05F33`** (A=world X px, X=world Y px, Y=slot → OR of hitbox collision bytes in `$5DA4`) | ✅ | Disasm-audited 2026-07-09. `xAdj -= u16($C42A1F+type*2)`; `yAdj -= u16($C42A41+type*2) += u16($C42AEB+type*2)`; hitbox w/h counts at `$C42AA7`/`$C42AC9`. Left/right column scans `JSR $5639`/`$56D0`. |
| `0x0029CC` | **Walk gate** — `JSL $C05F33; AND #$00D0; BNE blocked` | ✅ | Nonzero blocks the `STA $0B8E,X` pos update at `0x0029F9`. |
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
