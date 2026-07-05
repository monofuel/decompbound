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
