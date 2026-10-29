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

The Inspect tab identifies world pixels, the row-major region index and grid
position, logical map tileset, palette group, 32×32 arrangement ID, 8×8 CHR tile,
and the tile's priority/flip flags. Labels are numeric rather than inferred town
names. Previous/next region follows atlas order, including stored interior and
unused regions; this is not a door-connected tour of towns.

The World tab controls the story flags referenced by the original palette and
arrangement loaders. Named changes appear first: Onett daylight, Winters
lighting, Threed / Saturn ladder, Deep Darkness revealed, and the Peaceful Rest
Valley bridge. Threed's daytime palette and Saturn Valley's completed ladder
share flag `$0047`; they are one control because that is how the game connects
them. Other verified loader conditions retain numeric labels while their story
meaning remains under investigation.

Click a checkbox to toggle it; the mouse wheel over the sidebar scrolls the
list. Tab or Paddy Select switches tabs. In World, arrows / D-pad move the
focused row and Enter / Space / A toggles it; Escape / B returns to Inspect.
WASD / left stick still pan, and mouse gestures over the map retain their normal
behavior. Reset world flags clears every selection. Changes are session-local:
startup remains all flags clear, without writing the ROM, SRAM or screenstates.

Flags can also be selected before the first frame:

```sh
make map-app ARGS="--flag:01A6=on --flag:011F=on --flag:0047=on"
make map-app ARGS="--flag:0120=on --flag:0044=on"
```

IDs are hexadecimal, with an optional `0x` prefix. Values must be `on` or `off`;
repeated settings for the same flag apply in command-line order. Unsupported
IDs are rejected. Toggles preserve camera, zoom, selection and responsive
layout while rebuilding affected scenery from immutable decoded resources.

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

### Story-dependent palettes and arrangements

Original `$C007B6` copies a `$C0`-byte palette record to WRAM `$0240`, supplying
six sixteen-color BG subpalettes at global palette indices 32–127. Transparent
slots also carry metadata: the first word is a story-flag selector, the word at
`+$20` an alternate palette address, and `+$40` an OBJ-palette source selector
consumed by `$C00778`. The OBJ override is not a map-animation index.

The browser reproduces palette redirection using the **selected numbered event
flags**, initially all clear. That default gives a deterministic base atlas;
it is not a snapshot of the player's story state or a promise of daytime
everywhere. The original loader
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

Winters also has a verified conditional palette: logical tileset 13, palette 0
starts at file `0x1AA8E7` with condition `0x011F`. Cleared flags redirect to
`0x1AAA67`; setting flag `0x011F` (WRAM `$9C2B`, mask `$40`) retains the
primary record. Original `$C007B6` confirms that changing only this bit changes
58 visible colors. In private `earthbound_20260818-021632.png`, this flag is
set, and the original loader's visible colors exactly match live CGRAM.
Palette 1 of this logical tileset has no such condition. These checks establish
story-dependent palette selection, not the complete narrative meaning of the
flag or the cause of the reported neon-green dungeon entrance; that specific
arrangement has not yet been compared under both variants.

Original `$C006F2` also applies arrangement replacements before the map is
published. Its 20-entry pointer table at `$D01598` selects ordered lists of
conditions and `(destination, source)` arrangement pairs. The native renderer
applies the same replacements in their original order for the selected flags.
The cleared baseline performs 56 pair applications across drawing tilesets 3,
6 and 8. The full table has nine conditional records, 157 ordered replacement
pairs and seven distinct flags. Palettes reference nine flags; the union of
these two loader inventories is 15 numbered flags. Conditions are discovered
from the supplied ROM, not a bundled copy of its patch data. Each change starts
from untouched decoded arrangements, so repeated toggles cannot accumulate old
bridge or ladder tiles.

The two loaders have different comparisons at the exact `$8000` condition:
palette redirection compares against `condition > $8000`, while arrangement
replacement compares against `condition >= $8000`. Original `$C21628`
decrements flag zero to `$FFFF` and reads WRAM `$BC07` bit `$80`, outside the
numbered event store. The viewer keeps that out-of-state bit clear and exposes
only flags `$0001..$7FFF`. Original-loader calls with locally authored `$8000`
conditions verified both edge cases; the synthetic palette regression retains
the redirect case without a game-data fixture.

Animated graphics remain at their base uploaded frame. The World catalog
covers all numbered conditions in the verified palette and arrangement loaders;
it does not execute arbitrary story scripts or actors. Palette animation,
characters, encounters, interactive doors, collision, general scene distortion
and playable navigation remain outside this release. Neighboring stored
interiors can be adjacent in the atlas while the
game normally clips or hides them during play.

### Deep Darkness investigation

The reported non-black patches are reproduced with flag `$0120` clear. The
palette path is verified: logical tileset 6 / palette 3 starts at file
`0x1A8D27`; cleared `$0120` redirects to `0x1A8F67`. Setting it selects the
revealed palette. Both records have zero palette-animation metadata at `+$60`,
`+$80` and `+$A0`.

A stronger scene check starts from private pre-Hawk-Eye
`earthbound_20260725-183101.png`, updates the authoritative party coordinates
`$9877/$987B` as well as the leader entity, and advances 120 original frames
into the affected region. At camera `(4929,7136)`, `$0120` remains clear;
`TM=$17`, `TS=0`, and window/color math/HDMA are disabled. Background rendering
contains 7,895 non-black pixels. OAM adds only 204 party pixels and does not
cover the scenery patches. With animation and live arrangement state aligned,
the atlas matches all 57,344 original background pixels.

This disproves the provisional black-cover-sprite explanation; it does not
establish that this counterfactual location is reachable in normal pre-Hawk-Eye
play or that our PPU is an independent hardware reference. An independent
decode of two affected pixels using the
[Nintendo SNES Development Manual](https://floating.muncher.se/bot/manual/book1_text.pdf)'s
mode-1 addressing and transparency rules finds colored BG1 pixels and transparent
BG2 pixels, not an opaque black overlay:

| World pixel | BG1 tile word / pixel index / CGRAM color | BG2 tile word / pixel index |
|---|---|---|
| `(5010,7160)` | `$15D8` / 6 / `$39EB` | `$0000` / 0 |
| `(4996,7142)` | `$1514` / 13 / `$20BA` | `$3514` / 0 |

Changing priority cannot hide these particular pixels with the scene inputs
observed. The manual's mode-1 priority table (appendix A-19) and index-zero
transparency rule (A-10/A-17) agree with the active compositor. No guessed
opaque mask is presented as original behavior. The reported difference from
normal console play remains tracked in [issues.md](issues.md); matching our
own PPU alone does not establish hardware correctness.

The original game also has a flag-controlled invisible collision object:
TPT `$04CF`, file `0x0FDB44`, references transparent sprite resource `$01C8`
and flag `$0120` with condition byte 1. Its only placement is `(6016,7960)`,
in the bank-`$CF` list at file `0x0F82FD`, selected from the 32×40 placement
pointer table at `$CF61E7`. Original `$C0222B` reads the four-byte placement
record; `$C0244A..$C02470` admits the object when `$0120` is clear and skips
it when set. Full population mode `$4A58=1` is required when rebuilding a
scene after a coordinate warp; normal incremental population deliberately
skips objects already inside the camera viewport.

In two fresh branches of the private pre-Hawk-Eye capture, original population
creates the object only with the flag clear. Starting at `(6016,7940)`, identical
Down input stops the leader at Y=7941 with the object, versus Y=7960 without
it. Calling original `$C02140` to remove only that object while leaving
`$0120` clear permits movement to Y=7960 too. Thus this is a collision gate,
not a black covering sprite. This is an important limit on the earlier warped
scene comparison: the atlas can expose locations the game restricts before
the palette changes. It does not establish the complete normally reachable
camera boundary or close the human-reported visibility issue.

An independent [first-person report](https://gamefaqs.gamespot.com/boards/588301-earthbound/68394715)
also describes an invisible pre-Hawk-Eye barrier and colored scenery patches
after bypassing it with a walk-through-walls code. This supports the
normally-inaccessible-map hypothesis; its unspecified execution platform is
not a stock-console pixel reference. No community code or asset data enters
the implementation.

Reproduce the diagnostic with the user's own ROM and private capture:

```sh
nim r tests/world_map/private_shroud_scene.nim \
  /home/monofuel/Pictures/Screenshots/earthbound_20260725-183101.png
```

The diagnostic writes no state, images, or extracted assets.

The retained gate investigation checks the original metadata, transparent
graphics, conditional spawning and causal collision removal. It requires the
same private capture and does not claim to verify the complete walkable area:

```sh
nim r --path:src -d:debug src/probes/probe_story_hardware_gate.nim \
  /home/monofuel/Pictures/Screenshots/earthbound_20260725-183101.png
```

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

Story-state gates enumerate every combination of each resource's own condition
dependencies: 165 palette assignments and 30 complete arrangement states.
They compare original loader output word-for-word, then exercise named visual
changes, repeated set/clear sequences, snapshots and idempotent reset. The
World controls and CLI overrides also run through the isolated window gate.

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
