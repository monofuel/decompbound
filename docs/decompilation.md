# Decompiling the data — the other 90% of the ROM

**Status:** the big open frontier. Hub doc for the data reverse-engineering
tracks.

Goal 1 conquered the boot-path **code** (266 regions, byte-exact, round-tripped
— `docs/goal-1.md`). But as `docs/goal.md` says up front, **most of the 3MB ROM
is data, not code**: text and event scripts, graphics, music, maps, and game
tables. "Decompile EarthBound" is mostly *this* — understanding the data. Goal 1
conquered the machine; these tracks conquer the game.

## The verification principle: round-trip, again

Goal 1's ungameable metric was `assemble(disassemble(bytes)) == bytes`. Data
gets the exact same honesty rule:

> **`encode(decode(bytes)) == bytes`**, per asset, against the gold ROM.

If we claim to understand a format, we must **decode** it to a structured/visual
form *and* **re-encode** it to the original bytes. A viewer that renders
something plausible proves nothing; a byte-exact round-trip proves we actually
understand the layout, including compression. This is what makes clean-room RE
honest and lets us cross-check community docs (CoilSnake) without copying them.

## The instrument: the emulator does dynamic RE

Static disassembly stalls on data — "what are these 40 KB of bytes?" The
emulator answers it dynamically by watching the game decode its *own* data:

- **Graphics:** watch DMA to VRAM → you've mapped which ROM bytes became which
  tiles/palettes.
- **Audio:** hook the APU upload path → you've captured a song's sequence +
  sample set as the game sends it.
- **Scripts:** hook the text-print / event-interpreter routine
  (`docs/text-log.md`) → you watch script bytes decode into dialogue and events
  live.

So the emulator work is **on-path for decompilation**, not a detour: static
disasm finds the interpreter, dynamic tracing reveals the data it eats.

## The browsers: one explorer per format

The silky explorer stubs already reserved in the repo are the intended viewers,
one per data track — each format we crack gets a browser:

- `sprites_explore.nim` → graphics track
- `map_explore.nim` → maps track
- `sound_explore.nim` → audio-data track (and the music jukebox, `docs/apps.md`)

Cracking a format and building its explorer are two halves of one job.

## What's committable (every track)

The same line holds across all tracks (AGENTS.md "Copyright hygiene",
`docs/copyright-notes.md`): the **codecs, format docs, and extractors are ours —
commit them**; the **decoded / extracted data is the copyrighted asset — never
commit it.** Extraction runs against the user's own ROM at build/run time and
writes to a git-ignored path (`bin/` or `extracted/`). The repo teaches how to
read the game; it never *contains* the game. This matters most for the scripts
track — dialogue is a literary work — but applies equally to graphics, audio,
maps, and tables.

## Prior art: CoilSnake (clean-room)

The EarthBound modding community's tool (CoilSnake) already decomposes the ROM
into all these formats. This project is clean-room *for the fun of it*
(`docs/goal.md`): we RE the formats ourselves, the round-trip property keeps us
honest, and CoilSnake's docs are a cross-check, not a source to copy.

## The tracks

| Track | What | Doc | Explorer |
|-------|------|-----|----------|
| 🎨 Graphics | Tiles, palettes, sprites, battle BGs, font, compression | `docs/graphics.md` | `sprites_explore.nim` |
| 🎵 Audio data | Song sequences, BRR instruments, SFX (ROM-side format + upload) | `docs/audio.md` (ROM-side section) | `sound_explore.nim` |
| 💬 Scripts | Dialogue text (char table + control codes) + the event/script system | `docs/scripts.md` | text-log + a script dump |
| 🗺️ Maps | Overworld tilemaps, tilesets, sectors, doors/warps, enemy placement | *(in this hub for now)* | `map_explore.nim` |
| 📊 Game data | Enemy/item/PSI/character-growth/EXP/shop tables | *(in this hub for now)* | `sram_info`-style dump |

### 🗺️ Maps (track, not yet its own doc)

EarthBound's overworld is a large tilemap assembled from **tilesets** + **map
tiles**, divided into **sectors** (each with its own music, tileset, teleport
rules), plus **door/warp tables** (where each exit leads) and **enemy-placement**
data (which encounters spawn where). Shares tileset/tile decoding with the
graphics track. Round-trip DoD: decode a map region → re-encode → byte-exact;
`map_explore.nim` renders the whole overworld as one big browsable image (its
stated TODO), with a keybind to overlay impassable tiles.

**Located (verified byte-exact):** a **tilemap pointer table** at file `0x100000`
(4-byte entries → bank `$CF`), **tilemap data** at file `0x101800` (2-byte
tile+attr words, standard SNES BG format), and **tileset graphics** at file
`0x3E408` (loaded via `JSL $C3E4CA` etc.).

- **Sectors** — the per-sector graphic-set config is an 8-byte-record table at file
  `0x03E250` (SNES `$C3E250`), resolved through a `~0x35`-entry RAM cache (`$88E4`)
  keyed by sector ID (`$89CA`, set via `JSL $C3E74F`). A single flat
  `{tileset, music, flags}` record isn't isolated (music/palette/teleport are split
  across tables). The **sector setter** is at file `0x043573` (takes a *pre-computed*
  sector ID in `A`, writes `$89CA`, then ID-derived buffer math via `$C08756`);
  callers pass the ID explicitly (some hardcoded, e.g. `LDA #$0000; JSL $C43573`), so
  there is **no simple `(X,Y)→ID` formula** — the sector is set on area-load /
  boundary-cross, not derived from continuous position. The walk-time boundary-cross
  recompute (likely a per-tile sector attribute or a grid lookup) isn't isolated yet.
- **Doors/warps** — *not* a flat table: exits are per-entity **script streams**
  run by the `[$80],Y` object interpreter (the same `$C09558` engine, see
  `scripts.md`), executor at file `0x009D9E` (`JML [$0A5A]`), chained via `$125A`.
  The per-map door *data source* (the real "table") is upstream in area-load: next dig.
- **Player position + collision (for pathfinding)** — the player/entity **world X/Y**
  is at WRAM `$0B8E,X` / `$0BCA,X` (indexed by entity slot; the player is the first
  active entity, usually slot 0) — byte-verified (81 `(LDA|STA) $0B8E,X` sites; `STA
  $0B8E,X` near file `0x9390`; screen-relative = minus scroll `$0031/$0033`). The
  **tile+attr reader** is at file `0x2640` (SNES `$C02640`): `LDA $D01880,X` returns
  the 2-byte tilemap word (data `0x101800`, ptr table `0x100000`) for a target tile.
  Walkability is a **branch-on-bit after that word load** — a passability bit in the
  2-byte tilemap word; the exact bit still needs a confirmed wall-contact trace to
  pin. Together these give a future `walkTo` its A* pieces: read `$0B8E/$0BCA`, index
  the tilemap via `0x2640`'s calc, test the step bit.

### 📊 Game data (track, not yet its own doc)

The flat tables that define the RPG: enemy stats + battle groups, item
definitions, PSI, character stat growth and the **EXP-to-next-level** tables
(the pending EXP question lands here and in the save-report app, `docs/apps.md`),
shops, prices. Mostly fixed-width records — the most tractable data to map with
the `--find` value-locator approach (`sram_info.nim`), just against ROM instead
of SRAM. Round-trip DoD: decode a table → re-encode → byte-exact.

**Located (verified byte-exact):** the **EXP-per-level table** at file `0x158F51`
(SNES `$D58F51`), 4-byte LE u32, four per-character tables `0x190` apart
(Ness/Paula/Jeff/Poo). Answers "EXP to next level" = `table[level] − current EXP`.

- **Enemy-stat table** — `0x30`-byte records; verified against Pogo Punk (record
  at file `0x15C6DE`): `HP` u16 `+0x00`, `PP +0x02`, `EXP-reward +0x04`,
  `money +0x08`, then two 3-byte gfx pointers, and `Offense/Defense/Speed` as u16
  at `+0x17 / +0x19 / +0x1B` (odd offsets — our review corrected grok's off-by-one).
  Canonical table base + indexing code: next dig.
- **Item table** — `0x27`-byte records; `price` u16 at `+0x00` (verified: Cookie
  `$7`, Bread Roll `$12`, Hamburger `$14`). Type/equip/effect fields + base id-0:
  next dig.
- **PSI table** — located at file `0x158C50` (SNES `$D58C50`), ~15-byte records
  directly before the EXP table; verified byte-exact, with PSI Rockin α's PP=10
  (`0x0A`) present. Fields (per grok, tentative): name idx, greek tier, type,
  target, effect-id (u16), Ness/Paula/Poo learn levels, menu position, and a
  4-byte description pointer. **Caveats:** the exact per-field offsets (PP vs
  power vs element) and the record *count* aren't pinned — 53×15 would overrun
  the EXP table at `0x158F51` (only ~51 fit), so the width/count needs a dynamic
  trace. Learn-set is embedded in the same table.
- **Battle-groups / enemy formations** — the formations data table at file
  `0x10D74C` with its pointer/index table at `0x10C80D` (8-byte entries: a far
  pointer + a count/assoc word, e.g. `b1 d6 d0 00 00 00 00 03`). Formations are
  **variable-length**, `0xFF`-terminated (e.g. `00 01 03 00 01 de 00 ff` at the
  data base — small bytes are enemy IDs/counts). **Confirmed:** the pointer entries
  are 8 bytes (a 24-bit far pointer into the formation block + a 4-byte count/assoc
  word); formations are variable-length, `0xFF`-terminated lists of enemy
  descriptors.
- **Shops** — the store-inventory table at file `0x1578B2`, 66 entries × 7 bytes,
  each entry 7 `u8` item-IDs (`0` = empty slot) into the item table; prices come
  from the item table, not per-shop. Verified byte-exact (shop 0
  `00 00 00 00 00 00 d1`, shop 1 `00 fd 00 ba 00 84 a7`); ends right before the
  PSI-teleport table (`0x157A80`).
- **Character stat-growth — the `0x15EC5B` guess is REFUTED.** No code reads that
  28-byte block (its address bytes appear nowhere in the ROM; the 4×7 grouping
  gives nonsensical growth values), so it's most likely enemy-table tail, not
  stat-growth. The **real** per-character growth lives near file `0x159589` (SNES
  `$D59589`): the level-up code around `~0x0033xx` does `LDA $D59589,X` + the 8×16
  hardware-multiply helper at `$C08FF7` (writes `$4202/3`, reads `$4216`) for the
  vit/IQ → HP/PP target calcs. **Now mapped:** `0x159589` is a table of `0x5E`-byte
  records; a level→block **selector table at `0x158F23`** (verified — leading zeros
  then `01 a1 01 a2 01 a0 01 a3 …`, sitting right before the EXP table `0x158F51`)
  maps a level to a block, and the level-up routine at `~0x0032EC` computes
  `*0x5E + const` (consts `0x1C / 0x21 / 0x29 / 0x3C` select HP/PP-target vs
  stat-gain fields) via `$C08FF7`, then `LDA $D59589,X`. The exact per-field /
  per-char byte layout (mixed u16/u8 within the record) is the last detail to nail.

## Relationship to the numbered goals

- **Goal 1 / 1.5** (`docs/goal-1.md`, `goal-1.5.md`) = the **code** side: byte-
  matching disassembly, then cleaning generated scaffolding into named modules.
- **These tracks** = the **data** side: the other 90% of the ROM.
- **Goal 2** (the emulator) = the **instrument** that makes data RE tractable.
- **Goal 3** (native reimplementation) **needs all of this** — you can't
  reimplement a game whose data you can't read. These tracks are the
  prerequisite for it.

Together, code + data + a working emulator to check against = an actual
decompilation.
</content>
