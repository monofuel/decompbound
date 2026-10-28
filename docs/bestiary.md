# Pocket Bestiary

A single-window Nim browser for enemy battle portraits, core stats, encounter
backgrounds and automatic battle music, all read from your own ROM at runtime.
It shares Pocket Jukebox's cream/navy/pink theme and its audio output, and uses
Pocket Backgrounds' native renderer and enemy-to-encounter catalog.

```sh
make bestiary-app
make bestiary-app ARGS="--enemy:134"
make bestiary-build                 # Build only; no desktop window.
make bestiary-app ARGS="--mute"      # Visual-only; never opens an audio device.
```

Use the normal development shell (`nix develop` on this machine). `ROM=...`
selects a user-supplied 3 MiB US ROM, with or without its 512-byte copier header.
CLI options also include `--rom:PATH`, `--fullscreen`, `--frames:N`, `--trace`
and `--help`. No game assets, names, audio, memory images or captured scenes ship
in the repository. Generated local previews remain in ignored paths.

## Browsing and playback

The 960×720 logical canvas has a searchable enemy sidebar, a 256×224 native scene
shown at 2×, core stats and transport controls. The portrait is centered at its
original pixel size over the animated background. Window resizing fits the whole
canvas with nearest sampling and preserved aspect ratio; fullscreen shows the
whole bestiary. Its presentation omits battle UI and encounter letterboxing.

The supported record window is **IDs 1–230 in ROM order**. Duplicate names remain
separate numbered entries. This is the existing name decoder's supported window,
not a claim that an engine bounds check proves 230 is the final possible id.
Search matches case-insensitive name substrings or an exact numeric id (`134`
or `#134`). Selection is retained when it still matches; otherwise the first
match is selected. Empty results clear the scene and stop music. Clearing the
query restores the remembered enemy where possible.

Core stats are base HP/PP, EXP reward, money reward, drop item and listed drop
rate. No drop item is shown as **None**; drop frequency zero means **1/128**, not
never. These are record values, not predictions for every scripted battle.

Music follows the **selected enemy's own song field**, rather than the first
member of a selected encounter. Changing background variants leaves music alone;
changing enemies with the same song preserves playback position. Different-song
changes stop stale music immediately and coalesce loading after 150 ms, keeping
rapid navigation responsive. Zero or unused song assignments stop previous music
and show **No assigned theme**. Tracks loop through the existing SPC/DSP player.

Pause freezes both background and music; restart resets both and plays. Reset
preserves pause. Mute keeps song time advancing. Volume percentage and mute track
the app's actual mixer stream, including external slider changes. When system
mixer control is unavailable, local gain preserves the controls. Pending volume
and mute requests survive attachment/reattachment; local silence guards the
transition until writes complete and a fresh server snapshot arrives. Concurrent
external mixer changes win as the actual backend state. Audio and animation
continue unfocused, while navigation requires focus.

| Action | Keyboard | Paddy |
|---|---|---|
| Enemy / page | Up/Down; PageUp/PageDown; Home/End | D-pad/stick Up/Down; L2/R2 |
| Background variant | Left/Right | L1/R1 |
| Pause/resume both | Space | Start |
| Restart and play | Enter | A |
| Reset, preserving pause | R | B |
| Music mute | M | X |
| Volume | Minus/Plus | D-pad Left/Right |
| Fullscreen | F11 | Y |
| Search | Slash, Ctrl+F, or mouse field; Ctrl+A clears | Browse the filtered list |
| Exit | Escape outside search | Select+Start |

While search has text focus, letter/space shortcuts are suppressed. Enter or
Escape leaves search without exiting; a held Escape must be released before a
second press can quit. Mouse selection, wheel, page and transport buttons use
the same model as keyboard and Paddy. Held navigation/volume repeats; transport
actions are edge-triggered. `--mute` disables the mute button's audio operation.

## Portrait format and original-code evidence

The enemy record does **not** contain two direct far graphics pointers. That
older claim, including the old `+0x0C/+0x0F` candidates, is superseded.

| Data | Headerless file offset / record field | Evidence |
|---|---|---|
| Enemy configuration | `0x159589`, stride `0x5E` | `$C24D88` multiply; `$C2B6FA` initialization |
| Name | Enemy `+0x01`, up to 25 encoded bytes | Existing `battle_formation.decodeEnemyName` |
| HP / PP | `+0x21/+0x23`, u16 | Initialization loads `$C2B778/$C2B78C` |
| EXP / money | `+0x25` u32 / `+0x29` u16 | Reward consumers `$C26345/$C26260` |
| Drop frequency / item | `+0x57/+0x58`, u8 | `$C24DAD/$C24D92`; [drop research](sword-of-kings.md) |
| Enemy theme | `+0x37`, u8 | `$C24A56`; [battle music](../src/decompbound/battle_music.nim) |
| Standard sprite reference | `+0x1C`, u16, 1-based; zero absent | `$C2EF49/$C2F0F1`, decrement/index `$C2F007` |
| Palette reference | `+0x35`, u8 | `$C2EF59`; five shifts multiply by 32 |
| Sprite resources | `0x0E62EE`, 110 × 5 bytes | Three-byte far pointer, unused fourth byte, dimension byte; `$C2EE0B` |
| Palette rows | `0x0E6514`, raw 32-byte BGR555 rows | `$C2EF73..$C2EF82`, far copy `$C08ED2` |

All 32 referenced palette rows (0–31) are supported. This bounds the supported
catalog; it does not prove the entire palette table ends there. Index zero is
transparent. A malformed reference or truncated resource raises an error; it
must not be mistaken for a valid absent portrait or replaced with a black palette.

Dimension codes describe these native pixel sizes:

| Code | Size | Sprite-table entries |
|---|---|---|
| 1 | 32×32 | 24 |
| 2 | 64×32 | 5 |
| 3 | 32×64 | 40 |
| 4 | 64×64 | 36 |
| 5 | 128×64 | 4 |
| 6 | 128×128 | 1 |

The classifiers `$C2EFFD/$C2F04E` and painter `$C2EAEA` independently establish
these sizes. Decompression `$C41A9E` stages planar 4bpp CHR at `$7F8000`.
The original `$C2EE60..$C2EEDD` shuffle copies four 128-byte tile rows per 32×32
block into `$7F0000`, using `$C3F871` placement offsets and a 512-byte row stride.
Blocks and their 4×4 tiles assemble row-major. Display-list records at `$AAD6`
are **signed Y, tile, attributes, signed X, flags**, as consumed by the adopted
[`emitSpriteElements`](../asm/emitSpriteElements.asm) routine. Swapping X/Y would
incorrectly transpose nonsquare portraits.

The public `BestiaryLibrary` owns normalized ROM/catalog data and a lazy portrait
cache keyed by sprite+palette. The key is checked before decompression. Shared
assets retain the requested enemy identity, and separate libraries do not share
item-name or image caches. The scene and controls reuse their pixel buffers.

## Coverage and remaining work

There are **213 standard portrait references**, covering **all 110 sprite assets**,
and **17 named entries without a standard portrait**: 34, 160–168, 213, 215,
219–221, 225 and 229. All remain browsable with their available stats, music and
backgrounds. Zero references may use special/scripted rendering; no image is
invented for them. Enemy 218 uses the sole 128×128 standard asset (index 107).

The browser uses ordinary encounter presets. Scripted boss transitions and the
group-478 special arrangement retain the limitations documented in
[battle backgrounds](battle-backgrounds.md). Native centered presentation and
black backdrop are intentional; this is not a recreation of a complete battle.

Future work: offense/defense/speed, resistances, castable actions/PSI (including
the Mani-Mani shield question), overworld sprite identities, scripted portrait
phases, and a machine-readable enemy CLI. `bestiary/integration` preserves old
unverified research for selective investigation; it has not been merged wholesale.
No ability or resistance is inferred from names or from missing data.

## Verification

```sh
make bestiary-test
make bestiary-window-test
make jukebox-test
make jukebox-volume-test
make battle-bg-test
make compare
```

Synthetic tests cover fields, drop boundaries, header handling, all six planar
geometries/transparency, cache hits, cross-ROM palette/item isolation, malformed
resources, search/duplicate identities, navigation, debounce, coupled transport,
shared-song continuity and resized mouse/nearest scene pixels.

The required-ROM integration sweep validates all 230 records, 213 portraits,
110 assets, 32 palettes and all six dimensions; absent ROM is an error. The
original-code helpers under `tests/bestiary/` execute:

- Original decompression for every asset and both original dimension classifiers.
- Palette staging and actual CGRAM DMA for all 32 referenced rows.
- Original sprite painting **through tile shuffle** for all 110 assets. A separate
  reconstruction from emitted display lists and shuffled tiles pixel-compares
  all 213 enemy/palette combinations with the native decoder.
- Original HP/PP initialization copies for all 230 records, plus named
  instruction chains for the reward/drop field consumers. Synthetic fixtures verify
  byte widths and values; these checks do not claim full battle reward simulation.

The isolated Xvfb/private-audio-server tests exercise real selection/search,
same-song continuity, automatic different themes, selecting while paused,
external mixer/slider changes, mute and unrelated-PID isolation, resized mouse
input, unfocused clocks, exit and audio-free startup. Shared-output checks cover
requests made before mixer attachment, reattachment, mute-time progression,
pause freeze, competing external writes, rapid changes before acknowledgement,
rejected operations and releasing the APU on close. The C ABI check includes the native
mute function's full C integer parameter.

Original decompressor equality is stronger than a semantic codec round trip;
none of these tests claims the greedy encoder recreates original compressed
bytes. All test machine state is generated locally from the user ROM, with no
captured memory or screenshots committed. Physical visual/audio/controller
checks remain in [human verification](human-verify.md).
