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

### 📊 Game data (track, not yet its own doc)

The flat tables that define the RPG: enemy stats + battle groups, item
definitions, PSI, character stat growth and the **EXP-to-next-level** tables
(the pending EXP question lands here and in the save-report app, `docs/apps.md`),
shops, prices. Mostly fixed-width records — the most tractable data to map with
the `--find` value-locator approach (`sram_info.nim`), just against ROM instead
of SRAM. Round-trip DoD: decode a table → re-encode → byte-exact.

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
