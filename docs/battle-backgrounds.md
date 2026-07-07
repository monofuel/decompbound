# Battle backgrounds — RE the format + build the explorer

**Status:** format RE in flight. The iconic psychedelic backgrounds — a great toy that
secretly cracks a format.

The goal: **reverse-engineer EarthBound's battle-background data**, then build an
**animated explorer** — browse all ~300 backgrounds, watch them warp, mix layers. It's
listed in `docs/stretch-goals.md` (the "battle-background player"); this is its own track
because it's meaty and beloved.

## What a battle background *is*

EarthBound's battle backgrounds are **layered + animated**: typically two layers (one per
BG plane) blended with color math, each carrying its own animation — horizontal/vertical
scroll, a sine-wave **distortion/"compression"** warp (per-scanline offsets via HDMA), and
**palette rotation**. Hundreds of layers combine into the game's psychedelic library.

## Where it stands

- **We have the pieces**: the graphics compression codec (`gfx_lz`, byte-exact round-trip,
  `docs/graphics.md`) + the tile-animation machinery RE'd (per-frame CHR-DMA queue
  `$C0823C`, palette-cycle `$C081C8`, effect command-lists `$C59400+`).
- **RE progress (from the dig):** the per-layer **animation lists at `$C59400`** (keyed by
  layer ID) drive the CHR-DMA queue, palette-DMA queue, HDMA line-offsets, and scroll each
  frame — the `18 07` + `04 xx` streams are the distortion-wave / animation params. Layers
  **combine on BG1+BG2 with color math** (sub/add) + windows for the classic look. Battle
  paths: `code_00B65F` / `code_00B525` / `code_019EE6`; the NMI upload queues live in
  `code_008000`.
- **Format RE'd (2026-07-07) — complete enough to build the renderer.** The **layer table**
  is at `$CADEA1`: **17 bytes/entry, ~327 layers**. Per entry:
  - `[0]` graphics index, `[1]` palette index
  - `[3–7]` palette-animation (type / params / #palettes / speed)
  - `[8–11]` scroll / translation ("Mov")
  - `[12–16]` effects — the `$C59400` anim-list reference + distortion / HDMA / CHR-DMA /
    palette-cycle params (drives the per-frame warp).
  - Indices resolve through parallel far-pointer tables: **gfx `$CAD9A1`**, arrangement
    `$CADB3D`, **palette `$CADCD9`** (4B each), plus scroll `$CAF458`, distortion `$CAF908`.
- **Background-ID → layers**: table at **`$CBDA9A`** — `layerA:u16, layerB:u16` pairs
  (`B=0` = single layer), the two layers combining on **BG1+BG2 with color math**. One
  layer's compressed gfx round-tripped **byte-exact** via `gfx_lz`. The full pipeline
  (bg-ID → layer pair → decompress gfx + palette → run anim params) is now documented.

## The frontier — the battle-BG data structures

1. **Layer table** — how many layers, the table base, each entry (compressed-graphics
   pointer + palette + animation params). Where the layer CHR/tilemaps live.
2. **Combine** — a background ID → one or two layer indices; the two-layer blend on
   BG1/BG2 via color math.
3. **Animation params** — per layer: effect *type* (h-scroll, v-scroll, the sine
   distortion wave, palette rotation, translation) + params (speed, amplitude, frequency).
   This is the HDMA line-offset table + palette-cycle data that makes them breathe.

## Delegatable tasks (pick one)

1. **RE the layer table + graphics** — the table base + entry format; decode a couple
   layers via `gfx_lz` (confirm they're compressed + round-trip).
2. **RE the background-ID → layer(s) mapping + the color-math combine.**
3. **RE the animation-parameter format** — the effect-type enum + params; cross-ref the
   HDMA distortion tables + the palette-cycle routine (`$C081C8`).
4. **Build the renderer** — decode a background's layers + run its animation params
   (scroll + distortion + palette cycle) → an animated frame sequence, headless first.
5. **The explorer UI** — a silky browser: scroll through all backgrounds, mix any two
   layers, watch them animate live. A mini battle-BG *generator*.

**Verification (the round-trip rule):** a decoded layer re-encodes byte-exact against the
gold ROM; a rendered background pixel-compares against an emulator battle frame.

## Definition of done

- [ ] The layer table + background-ID mapping + animation-param format are documented,
      byte-evidenced.
- [ ] A layer round-trips byte-exact (`encode(decode(bytes)) == bytes`).
- [ ] An explorer renders every background **animated**, browsable, with layer mixing.

## Related

`docs/graphics.md` (compression + tile/palette), `docs/stretch-goals.md` (the
battle-BG player), and the tile-animation RE (the CHR-DMA / palette-cycle / effect tables).
A `Ctrl+3` save-state *inside a battle* lets the trace tool watch the exact HDMA + palette
writes for that background — the fastest way to pin an animation's params.
