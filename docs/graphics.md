# Graphics data format (decomp track)

**Status:** NOT STARTED (was a stub). A data-decompilation track — see the hub,
`docs/decompilation.md`.

Reverse-engineer how EarthBound stores its **visual assets** in the ROM: the
tiles, palettes, sprites, backgrounds, font, and window graphics — including
whatever **compression** the game uses. This is the format whose mystery
inspired the emulator work in the first place.

## What's in scope

- **Tiles / character data** — SNES planar bitplanes (2bpp / 4bpp / 8bpp).
- **Palettes** — CGRAM entries, 15-bit BGR555.
- **Sprites (OBJ)** — the overworld NPCs + player, battle enemy sprites; their
  tile + palette + frame/animation layout.
- **Backgrounds** — overworld map tilesets and the famously **layered, animated
  battle backgrounds** (the scrolling/warping psychedelic effects).
- **Font + window graphics** — the text-window tiles (shared with the scripts
  track, `docs/scripts.md`).
- **Title / logo graphics** — the EarthBound logo, "War Against Giygas" card.
- **Compression** — EB does not store all graphics raw; identifying and
  round-tripping the compression scheme is the crux of this track.

## The instrument: watch VRAM get filled

Rather than guess at ROM offsets, use the emulator (`docs/decompilation.md`):
set a watch on **DMA to VRAM/CGRAM** during a scene and record which ROM bytes
land where. That maps source bytes → on-screen tiles directly, and — critically
— captures the *decompressed* output next to the compressed source, which is how
you crack the compression.

## Round-trip verification (the ungameable part)

Per the hub's rule: for each graphic asset,
**`encode(decode(bytes)) == bytes`** against the gold ROM. A decoder that
renders a plausible-looking sprite proves nothing; re-encoding to the exact
original bytes (compression included) proves we understand the layout. Rendered
output can also be pixel-compared against an emulator frame as a secondary check.

## Components

1. **Tile/palette codecs** — planar bitplane ↔ pixels, BGR555 ↔ RGB. The easy,
   well-documented part; get round-trip green first.
2. **Compression codec** — identify the scheme (via the DMA-watch capture of
   compressed-in / decompressed-out pairs), then decode + re-encode byte-exact.
3. **Asset catalog** — where each graphic lives (offsets, dimensions, palette),
   grown outward from what the emulator observes being loaded per scene.
4. **`sprites_explore.nim`** — the silky browser that visualizes decoded tiles,
   palettes, and sprite frames (currently a one-line TODO stub).

## Findings so far (verified)

The sprite *output path* is mapped (the actual OBJ CHR + definition tables are
still open):
- **OAM DMA:** the NMI handler at SNES `$C08196` (file `0x8196`) DMAs the 544-byte
  OAM table (128 sprites × 4 + the 32-byte high table) from a WRAM buffer at
  `$000500` / `$000800` (double-buffered, selected by `$2C`) to the OAM data port
  `$2104`. Verified byte-exact.
- **Entity/sprite update loop:** `$C09470` walks the entity linked list (`$0A50`
  head) and drives each entity via the `$C09558` action-script engine — the same
  script dispatch as events/doors (`docs/scripts.md`). Animation is script-driven.
- **Still open (the graphics themselves):** the sprite-definition table (ID → CHR
  + palette + size + frame layout), the OBJ CHR location, and the routine that
  *builds* the OAM buffer from entity poses. These resisted static RE — best
  cracked by watching the OBJ CHR DMA during a known sprite (the emulator-as-
  instrument approach).

## Definition of done

- [ ] Tile + palette codecs round-trip byte-exact against gold.
- [ ] The graphics compression scheme is decoded **and** re-encoded byte-exact.
- [ ] A growing catalog of located assets (font, player/NPC sprites, a battle
      background) decoded and viewable.
- [ ] `sprites_explore.nim` browses decoded graphics on silky.

## Non-goals

- Re-drawing or modifying assets — this is *reading* the format, not romhacking.
- Re-implementing the PPU compositor (that's the emulator, Goal 2).

**Scope:** data RE + codecs + a silky explorer. Feeds the maps track (shared
tileset decoding) and cross-checks the emulator's PPU. Parallel-safe.
</content>
