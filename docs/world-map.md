# Pocket Atlas and the world-map format

Pocket Atlas is a single-window Nim browser for the US EarthBound base atlas.
Outdoors and interiors occupy their original positions in one continuous
8192×10240-pixel space. The app reads the user's ROM and composes scenery
directly; it does not run the game or require a save-state.

```sh
nix develop
make map-app
make map-app ARGS="--x:6782 --y:10064 --zoom:2"
make map-build
```

`ROM="/path/to/your.sfc"` selects the local ROM. The normal 3 MiB US dump and
the same image with a 512-byte copier header are supported. The app defaults
to fitting the whole atlas. `--x:N` / `--y:N` choose a native world-pixel
position; `--zoom:fit|FACTOR` selects the overview or a power-of-two scale up
to 8×. `--fullscreen`, `--frames:N`, `--trace`, and `--help` follow the other
companion apps. This release targets the desktop Windy/OpenGL path.

## Controls and presentation

The app opens at 1200×800 with a pan-and-zoom viewport and an inspector/sidebar.
Mouse-wheel zoom anchors the world position under the pointer; a drag pans,
and a click selects a pixel. Resizing expands or contracts the map viewport;
larger windows and fullscreen show more scenery at the same native zoom.
The camera keeps its center and selection, and the whole-world overview
recalculates its fit. Controls remain readable at normal sizes and scale down
uniformly in small windows. The region grid and selection marker stay clipped
to the map, with mouse input following the resized layout.

| Action | Keyboard | Paddy |
|---|---|---|
| Pan | Arrows / WASD | D-pad / left stick |
| Zoom | Minus / Plus | L1 / R1 |
| Previous / next region | Page Up / Page Down | L2 / R2 |
| Inspect viewport center | Enter | A |
| Center selected region | C | X |
| Fit whole atlas | Home | Y |
| Region grid | G | B |
| Fullscreen | F11 | Start |
| Exit | Escape | Select + Start |

The inspector identifies world pixels, the row-major region index and grid
position, logical map tileset, palette group, 32×32 arrangement ID, 8×8 CHR tile,
and the tile's priority/flip flags. Labels are numeric rather than inferred town
names. Previous/next region follows atlas order, including stored interior and
unused regions; this is not a door-connected tour of towns.

Drawing resources are cached per ROM. The atlas retains compact placement IDs,
sector metadata and decoded tilesets/palettes, never an atlas-sized RGBA image.
Only the visible viewport is sampled, including at overview scales. The app
reuses its display texture while idle and redraws scenery when the camera changes.

## Independently derived storage

All offsets below are for the unheadered US ROM. No extracted data is shipped.

| Structure | Original source | Contract |
|---|---|---|
| Base arrangement lookup | `$C0A152` / near entry `$C0A156` | A=32px column, X=32px row; returns a 10-bit arrangement ID. |
| Placement bounds | `$C00B3F/$C00B7D`, `$C00C4C/$C00C8D` | Streaming loops bound 256 columns × 320 rows. |
| Eight low-byte row streams | `$C42F64`, file `0x042F64`, 8×4-byte pointers | Select pointer by `row&7`, then index `(row>>3)*256+column`. |
| Upper two placement bits | `$D75000/$D78000`, files `0x175000/0x178000` | Row bit 2 selects the source; shift `2*(row&3)` selects two bits. |
| Region resource selector | `$D7A800`, file `0x17A800` | 32×80 bytes; upper five bits select logical tileset, lower three palette group. |
| Region attributes | `$D7B200`, file `0x17B200` | 32×80 u16 words; `$C00AA1` returns the word and writes `$438E`. Individual flags remain uninterpreted. |
| Logical-to-drawing tileset | `$EF101B`, file `0x2F101B` | 32 u16 entries reference 20 drawing tilesets. |
| CHR pointers | `$EF105B`, file `0x2F105B` | 20×4-byte pointers selected by drawing tileset. |
| Arrangement pointers | `$EF10AB`, file `0x2F10AB` | 20×4-byte pointers selected by drawing tileset. |
| Palette pointers | `$EF10FB`, file `0x2F10FB` | 32×4-byte pointers selected by logical tileset. |

The original map reader combines the packed high bits with its selected row
stream's low byte. `$2888/$288A/$288C` cache the last coordinate and result.
Negative coordinates return `$FFFF`; positive bounds are enforced by streaming
callers, not by the small reader itself. The native API rejects coordinates
outside the verified atlas. Each resource region spans eight arrangement columns
and four rows: 256×128 pixels, for 2,560 regions.

Original `$C008C3` selects resources from `$D7A800`; its `$438A/$438C` inputs
are camera coordinates in 8-pixel units. Original `$C41A9E` decompresses CHR
to `$7F0000` and arrangements to `$7F8000`. All twenty CHR streams expand to
`$7001` bytes, but the loader queues exactly `$7000` bytes for VRAM. The last
decoded byte is therefore not rendered. Arrangements contain sixteen ordinary
SNES tile words in 4×4 row order; `$C0035B` independently selects a tile word
using arrangement index, tile column, and tile row.

### Two scenery planes

Original publication at `$C00EBD` keeps each arrangement word in BG1. Tile IDs
below `$180` also publish `word|$2000` to BG2; other words publish zero there.
BG2 uses the second CHR bank, byte offset `$4000` / tile offset `$200`.
The `$7000`-byte upload supplies 512 primary and 384 overlay tiles.

The native composite follows mode 1 with the game's BG3-priority setting:
BG1 low-priority, BG2 high-priority, then BG1 high-priority, with palette index
zero transparent. Both planes share the arrangement flips and palette bits.
There are no characters or BG3 menus in the browser. This split matters even
when the finished scenery appears to be one image.

### Base palettes and scope

Original `$C007B6` copies a `$C0`-byte palette record to WRAM `$0240`, supplying
six sixteen-color BG subpalettes at global palette indices 32–127. Transparent
slots also carry metadata: the first word is a story-flag selector, the word at
`+$20` an alternate palette address, and `+$40` an OBJ-palette source selector
consumed by `$C00778`. The OBJ override is not a map-animation index.

The browser reproduces palette redirection with **all numbered event flags
clear**. That gives a deterministic base atlas; it is not a snapshot of the
player's story state or a promise of daytime everywhere. The original loader
oracle checks every sector-referenced logical tileset/palette selection, including
redirects. Global colors 0–31 are black; all actual arrangements referencing
those subpalettes are transparent in both scenery planes.

Onett exterior is a verified example: logical tileset 1, palette 0 starts at
file `0x1A7FA7` with event condition `0x01A6`. When that flag is clear, original
`$C007B6` redirects to the nighttime record at `0x1A8067`; setting it retains
the daytime record at `0x1A7FA7`. Original flag reader `$C21628` locates this
bit at WRAM `$9C3C`, mask `$20`. Isolated original-loader calls match both
records exactly. Private night `onett_start.state` and daytime
`earthbound_20260706-210416.png` independently confirm the corresponding flag
states and loader results. Both palettes come from the ROM; nighttime is the
browser's cleared-event selection, not a different map geometry or missing
daytime asset.

Original `$C006F2` also applies arrangement replacements before the map is
published. Its 20-entry pointer table at `$D01598` selects ordered lists of
conditions and `(destination, source)` arrangement pairs. The native renderer
applies the same replacements with numbered event flags clear: 56 pair
applications across drawing tilesets 3, 6 and 8. They are part of the base
loader result, not an optional cosmetic patch.

Animated graphics remain at their base uploaded frame. Story-specific map
variants beyond this cleared-event baseline, palette animation, sprites, encounters, doors, collision,
distortion/color-math scene effects and playable navigation are outside this
release. Neighboring stored interiors can be adjacent in the atlas while the
game normally clips or hides them during play.

## Verification and decompilation

```sh
make map-test
make map-window-test
make compare
```

Synthetic checks cover tile compositing, flips, transparency, palette rows,
malformed references and streams, redirect cycles, camera transforms, zoom
anchoring, input routing and selection. The ROM gates require the user's ROM;
they do not claim success through missing-fixture skips.

The original-code layout gate checks all 81,920 placements, cache behavior,
negative coordinates, all 2,560 regions at four corners, and original graphics
and palette selectors. Asset gates execute original loaders for all 20 CHR and
20 arrangement streams, all referenced palette selections, and arrangement-word
lookup. Rendering gates compare native composition with independently staged
original data through the emulator's PPU.

The annotated map lookup prefix/tail, region-attribute reader and arrangement
tile reader are individually byte-compared against the ROM and promoted in
the manifest. The existing high-bit dispatch table now explains its actual map
role instead of the former action-script attribution. Resource tables remain
runtime data; copied bytes do not count as explained code.

Window checks use a private Xvfb display and Openbox (provided by `nix develop`), including actual
mouse, wheel, focus, resize, fullscreen, keyboard and idle-cache behavior.
Physical mouse/controller checks are in [human-verify.md](human-verify.md).

The locked Windy fork also fixes X11 wheel input reporting on both button
edges. Wheel scrolling is now emitted only on press and accumulated within a
poll; its independent X11 regression checks releases and batched gestures.

## Superseded bootstrap claims

`map_explore` used guessed graphics offsets and synthetic palettes and has been
retired. `$C02640` actually reads a 128×160 **encounter** lookup at `$D01880`
(file `0x101880`); the old `0x100000/0x101800` graphical-map claim was incorrect.
Likewise, `0x03E250` is UI window geometry, not a sector table, and `$89CA`
is used for UI window/status selection. These are not atlas selectors.

The source of the faithful map is the original loader chain above, not a
community asset dump, guessed palette, or captured VRAM image.
