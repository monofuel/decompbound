# EarthBound memory map — a living registry

**Status:** ongoing project. Seed entries below; grow as RE lands.
**Updated:** 2026-07-16.

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
| `$0024` | dword | **RNG seed** (32-bit LE: lo word `$0024`, hi word `$0026`) | ✅ | The game's PRNG state (SNES has no HW entropy — randomness is deterministic over this seed). **Advance routine `$C08E9A`** (file `0x008E9A`, 56 bytes → RTL; `src/decompbound/snes_src/rng.nim`): `seed_hi.lo * seed_lo.lo` via HW mul (`$4202`→`$4216`), fold `+$6D` into hi, rotate product into lo (carry forces high bit), return byte in A. **JSL-only, 59 call sites** (e.g. `$C2008C` battle roll, `$C02686` ~1/16 branch). **Cold-init `$C08121`**: fixed `$5678_1234` (`LDA #$1234;STA $0024;LDA #$5678;STA $0026`) → deterministic boot. Reimpl matched emulator 10/10; seed reproduces byte-identical across runs. RE'd 2026-07-21 (grok dig + verified). |
| `$0B8E` | word × slots | Entity **world X** array (stride 2) | ✅ | Player = **slot 24** → `+0x30`. Writer traced `$C04E15` (`$0B8E,X`, X=0x30). `touch_grass.nim` |
| `$0BCA` | word × slots | Entity **world Y** array (stride 2) | ✅ | Same layout as X. Player = slot 24. |
| `$89CA` | word | **Sector ID** (per-area music/tileset/teleport) | ✅ | Set via `JSL $C3E74F`; setter at ROM `0x043573`. ⚠️ reads `0xFFFF` in some loaded states — confirm save-state restore. |
| `$9831` | word | **Money** ($) | 🟡 | `touch_grass.readU16`; used for progress signal. |
| `$8650` | byte | **First text/window slot header** — `0xFF` = free (no window open) | 🟡 | `advanceDialogue` gate. `$8958` = focus (unreliable alone). Slot 1 = `$8654` (NPC/scene dialogue). |
| `$96C5` | far ptr (24-bit) | **Live dialogue script cursor** into ROM (bank $C0-$CF → HiROM file offset) | ✅ | Advances as chars print. Decoded by `getDialogueText` (`text_decode.nim`): storage byte = ASCII+0x30; control `<0x20` (dispatch file `0x1890E`); `0x15/16/17` = dictionary-token calls via far-ptr tables `0x8CDED/0x8D1ED/0x8D5ED`. EB dialogue is **VWF** so VRAM tiles are pixel glyphs, not chars — the script stream is the only reliable read. Verified 2026-07-10 vs SHA-1 of a private screenstate line (`tests/test_dialogue_decode.nim`). |
| `$9877` | byte | **Post-Pokey outdoor locomotion soft-lock bit (bit0)** | 🟡 | Live AgentOutdoor after Pokey talk: `$9877=0x59` (bit0 set) → thrash at meteor, pure pad/goHome stuck knock=10. Fixture `pokey_done` / `pokey_free`: `$9877=0x58` (bit0 clear). Clearing bit0 alone (`0x59→0x58`) unlocks continuous AgentHome → bedroom knock80 (`probe_9877_bit0`, 2026-07-24). Nearby `$987A` also differs but bit0 is the minimal fix. goHome clears bit0 in meteor band only until the game writer is RE'd. TODO: pin writer / script release. |
| `$99F2` | byte | **Story progress / knock-complete signature** | 🟡 | `$58` = knock-complete (post_knock / night Onett after sleep). `$C4` = later-story soft (midgame + day F12s). Later `$C4` alone → **captain 70** (Ness-only). Paula+C4→80; Jeff+C4→90. Day-leave map soft **captain 100** = later-story + outdoor + **py≥0x0500** (F12 210416 at y=0x05B5; night wall sticks at y=0x02A0). TODO: pin sleep writer `$00→$58` and Twoson-entry scene bit if finer than map Y. |
| `$988B..` | block | **Event flags / party** | 🟡 | Party ids `$988B..$988E` (Ness=1, Paula=2, Jeff=3, Poo=4). Enter-only doesn't flip story bits here. |
| `$4DBA` | byte | **battle-ENTRY/transition flag** (`1` only during the ~12f entry window, `0` in the live command-menu) | ✅ | `STA` file `0xD65A` / `STZ` `0xD1A8`. ⚠️ **NOT a reliable "in battle" indicator** — corrected 2026-07-20: a healthy live battle (command menu up, attacks executing) reads `$4DBA=0, $98A5=0, mode 0` (verified on `battle_menu_healthy.state`, extracted from a secret F12). Detect an ACTIVE battle by **BG mode 0** (`$2105`&7==0) + populated party structs `$4DC8`, not `$4DBA`. **Battle EXECUTION works headless from a loaded state** (A→Bash→"Ness attacks! 161 HP"→victory→overworld, `probe_battle_advance.nim`); only battle ENTRY aborts (task #19). Battle text is a SEPARATE buffer from `getDialogueText` (which returns "" mid-battle) — winBattle must read the battle-text buffer. |
| `$5D60` | word | **Battle result / end code** — `$0078` on victory | 🟡 | Grok battle RE 2026-07-11; sustained on win. |
| `$98A5` | byte | **Battle phase** — `3` = transition/init phase (dispatch `$C04B8B`: `$98A5==3 → JMP $C04C40 → JSR $C04AAD`) | ✅ | **Root cause of headless battle abort** (RE'd 2026-07-20, ROM-verified). Stays `3` the whole ~12-frame window; never promotes to phase 2 (`$C46698`) or mode-0. |
| `$5D7C` | word | **Battle-transition countdown** — seeded `$000C` (12), `DEX` each phase-3 frame | ✅ | Seed `STA $5D7C` at file `0x4A8D` (via `$C0D6A4 JSL $C04A88`). Tick+abort at file `0x4AB8`: `DEX; STX $5D7C; BNE; JMP $C04B4D` → `JSL $C04A7B` → battle END `$C0D19B` → `STZ $4DBA`. **The abort is intentional ROM logic** — on a healthy fight something must leave phase 3 / finish init BEFORE this hits 0. Headless never promotes, so it times out. Fix needs a healthy mid-battle F12 to diff the missing promotion writer (`docs/human-captures-needed.md` Capture 1). `$9883`=phase-2 gate (stays 0). |
| `$4DC8` | word×slots | **Battler pointer table** → structs (party then enemies when inited). Struct stride `$5F`; HP at `+0x0A`, PP at `+0x0C` | ✅ | Live: `$99CE` Ness, `$9A2D` Paula, … `isInBattle` = BG mode 0 + first ptr HP live. |
| `$E000` | 64×64 bytes | **Live collision page** — one byte per 8px coarse tile; **blocked iff `(byte & 0xD0) != 0`** | ✅ | Read by `$C05F33` (`LDA $E000,X`, DBR=`$7E`); walk gate `AND #$00D0; BNE` at file `0x0029CC` before the `$0B8E,X` pos write. Index `((cy&0x3F)<<6)\|(cx&0x3F)`, `cx=(xAdj>>3)`, `cy=(yAdj>>3)`; adj offsets from ROM tables below. Page **wraps mod 64 tiles** (512×512px window); loader that fills it from ROM not yet pinned. Verified vs live movement 4/4 dirs (`probe_walkable.nim`, 2026-07-09). Onett bytes: `0x00` open, `0x80` solid, `0x01/0x03` pass. |
| `$2B6E` | word × slots | Entity **collision type** (stride 2; player outdoor = 5) | ✅ | Indexes the `$C42A1F/...` offset + hitbox tables in `$C05F33`. |
| `$2CD6` | word × slots | Entity **sprite-group ID** / identity (stride 2) | ✅ | **Who is this slot?** Written at entity spawn `$C0200B` (`STA $2CD6,Y`) from DP `$2B`. Indexes ROM sprite-pointer table `$EF133F` (4-byte entries → bank `$EF`). Verified 2026-07-16 cross-state: `home_door` **slot 4** = `$0091` = Mom; same value on Mom in `home_downstairs_night` (slot 7) and `home_indoor` (slot 3); `pokey_free` nearest (slot 0) = `$002C` (Pokey) ≠ Mom; player/Ness = `$01B5`. May read `$FFFF` on some leftover slots that still hold a sprite — use companion `$29CA` then. Probe: `probe_entity_names.nim`. |
| `$29CA` | word × slots | Entity **sprite data pointer** (stride 2; = `table[group]+9`) | ✅ | Derived from `$2CD6` at spawn (`$C02019`). Mom = `$2A8A`, Pokey = `$204B`, Ness = `$4796`. More reliably non-`$FFFF` on active slots than `$2CD6`. Appearance key (shared by same-looking NPCs), not a unique TPT instance id. |
| `$0180/$0280/$02A0` | — | Battle-menu **font bases** (VRAM glyph hypothesis) | 🟡 | VRAM reverse-map is **garbage** mid-battle (VWF). Do not drive winBattle from tilemap alone. |
| `$8600`–`$9120` | EB strings | **Battle window text buffer** (command menu + actor labels) | ✅ | Storage = ASCII+0x30. Command options at `$89E7` Bash / `$8A14` Goods / `$8A41` Defend / `$8A6E` Auto Fight / `$8A9B` Run Away / `$8AC8` PSI (stride ~`$2D`, text @ record+7). Active actor name ~`$868C`. `getBattleText` / `screen.battleText()`. Verified 2026-07-20 `battle_menu_healthy.state`. |
| `$9C80`–`$A200` | EB strings | **Battle target / enemy name strings** | ✅ | e.g. `$9CD7` / `$9CF5` / `$A99E` (“Mad Taxi”, “Crazed Sign”). Same ASCII+0x30 encoding. Part of `getBattleText`. |
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
  `src/probes/probe_*.nim`
