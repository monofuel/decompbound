# Original EarthBound UI rendering

The DS companion reproduces the original Goods and battle status UI at native
256×224 resolution. The game screen remains complete. UI assets are decoded
from the user's ROM at runtime; no font bitmaps, window tiles, palettes or
reference captures belong in Git.

## Status-window composition

Original `$C207B6` enables a status panel and calls `$C203C3`. The latter builds
an eight-row, seven-column tile rectangle. The native counterpart is
`eb_ui_frame.nim`; its tile words are compared directly against original
execution in `tests/integration_eb_ui_status.nim`.

- The counted roster is `$986F`, count `$98A4`; character records start at
  `$99CE` with stride `$5F`.
- `$C20445` selects tile row `$12` for the selected member and `$13` otherwise.
  The horizontal column is `16 - floor(7 * count / 2) + 7 * slot`.
- The constructor's WRAM destination is `$7DFE + row*64 + column*2`.
  This address is a staging-buffer coordinate, not a screen pixel address.
- Character `+$4F` supplies border palette attributes. `$0C00` selects the
  incapacitated treatment: palette 3 for the interior and an extra `$0800`
  on meter tile words (`$C20416`–`$C20443`).
- The fixed-width name occupies up to four tiles per row. Name tile bases
  are `$2A0 + (id-1)*4` and `$2B0 + (id-1)*4` (`$C204D5`, `$C20579`).
- The eight HP/PP label tile IDs come from ROM `$C3E3F8` / file `0x03E3F8`.
- HP/PP meter tile words occupy `$8969 + slot*24` and `$8975 + slot*24`.
  The original full constructor calls `$C20F08` and `$C20F26` respectively.

## Conditions

Character `+$0E` through `+$14` is a seven-byte condition block. Original
`$C223D9` selects a status icon; `$C22474` selects the interior palette.
Both prioritize group 0, then group 3, then the remaining groups in ascending
order. They index seven groups of seven 16-bit entries at:

| Selector | SNES | File offset | Empty result |
|---|---|---|---|
| Icon, `$C223D9` with X=1 | `$C45A27` | `0x045A27` | 7 |
| Palette, `$C22474` | `$C45AEB` | `0x045AEB` | 4 |

`eb_ui_status.nim` decodes those tables from the loaded ROM. The integration
test calls both original routines with every entry and competing groups,
then compares native frame construction with `$C207B6` for one to four
members, name lengths 1/4/5, selected/unselected slots, and all four border
palette variants. Inputs are generated; no captured machine image is required.

```sh
nim r tests/integration_eb_ui_status.nim
```

## Font and meter investigation

The original text renderer is `$C44E61`; the width walker is `$C44751`.
Five twelve-byte descriptors at `$C3F054` / file `0x03F054` contain the
width pointer, bitmap pointer, glyph stride and glyph height. The original
glyph index is `(storageByte - $50) & $7F`. Bitmap packing and blitting are
verified against original execution by the font regression.

Each bitmap is inverted 1bpp, column-major: `height` bytes describe an
eight-pixel column, MSB left, zero for ink. The stride divided by the height
gives the number of columns. Font 0 supplies proportional Goods text; fonts
2 and 3 supply fixed-six-pixel status names and eight-pixel-high window titles.
The live `$5E6D` byte supplies extra proportional-text spacing; the game sets
it to one at `$C201FF`, with temporary compact-text contexts elsewhere.

The common 2bpp stream is at file `0x200000` / `$E00000`: 0x754 compressed
bytes produce 0x1A00 bytes. Original `$C47C3F` calls `$C41A9E` then relocates
the digit section from `$7F1000` to `$7F2000`; `$C44963` publishes the common
tiles at VRAM word `$6000` and digits at `$7000`. Native tile IDs `$200..$29F`
therefore address decoded byte `0x1000 + (tile-$200)*16`.

Five three-byte descriptors at `0x201FB9` select 64-byte BGR555 palette rows
relative to `0x201FC8`. The one-based selector is `$99CD`. Non-Plain flavors
also decode `0x200754` over common tiles `$10..$16`; this stream produces
0x70 bytes. Original `$C47F87` copies the palette to `$0200`, clears color
zero and requests publication. Conditional scene palettes and later palette
patches exist, so the running core supplies the actual first 32 CGRAM colors
to the companion instead of approximating those scene decisions.

Original `$C47C3F` also builds the status names and condition graphics.
Names start two pixels into four tiles and use tile 7 as the background;
the native painter preserves that background under transparent glyph pixels.
The icon source selectors at `0x045A89` generate tiles `$2C0..$2DA`, combining
each source's ink with the original background planes. The asset regression
compares every generated icon byte and complete name pixels with that loader.

## Goods layout and frame

`$C198DE` visits all fourteen inventory slots, appending only nonzero items.
Equipped items receive the special `$22` marker (`$C19961`); `$C10B35`
forces its palette to 3 and maps it to the two tiles `$42`/`$52`.
`$C451FA`, called with two columns, fills across rows with an 88-pixel column
stride and 16-pixel row stride. The integration test executes that routine
and checks all fourteen coordinates; a sparse-inventory render also verifies
that later physical slots compact into the first visible cells.

Window records at `$C3E250` contain x/y/width/height in eight-byte records;
IDs 2 and 13 have the Goods size 24×16 tiles. The companion centers that
size at `(32,8)`. Its border follows `$C107AF`, using tiles `$10/$11/$12`
with palette 7, rather than the status panel's `$4/$5/$6` border. The title
uses seam tile `$16` around the small-font glyph tiles. All border/header
entries are compared against `$C107AF` for name lengths 1–5.

Run all required-ROM UI regressions with `make libretro-ui-test`. They decode
the user's own ROM and generate their inputs. Completed investigation probes
were retired after these contracts and tests were preserved here.

Meter simulation belongs to the running game (`$C2109F`). The companion reads
the existing displayed integer and fractional phase; it never advances meters
or guesses their rate. Character HP phase/integer are `+$43`/`+$45`, PP are
`+$49`/`+$4B`; settled values remain `+$47`/`+$4D`. Outside battle, settled
values are shown with no stale rolling phase. See [the DS evidence](earthbound-ds.md#live-meter-evidence).
