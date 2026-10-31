# EarthBound DS companion

The optional dual-screen libretro mode keeps the complete SNES game above a
read-only party companion. It runs the user's original ROM through decompbound;
it does not patch the ROM or replace the game's menus.

For configurable experimental game-view dimensions and desktop testing, see
[expanded viewport design](expanded-viewport.md). The companion retains its
original 256×224 layout.

The lower panel uses the game's actual bitmap fonts, window graphics and
palettes. A Goods window above the status panels shows the selected member's
items in the original two-column, seven-row order, with the original equipped
symbol. Empty inventory slots are omitted as in the game. Native battle-style
HP/PP panels sit below, in active roster order; the selected panel rises eight
pixels. Their rolling digits and condition icons follow live game data.
Character artwork, maps and touch-driven item/PSI actions remain outside scope.

## Build and launch

Build mono-retro-player from the matching feature branch using that repository's
normal development environment (`nix-shell shell-player.nix` on this machine):

```sh
make player-desktop
```

Then, from decompbound:

```sh
make libretro-ds-play
```

To resume a local F12 screenstate instead of cold booting:

```sh
make libretro-ds-play STATE="$HOME/Pictures/Screenshots/earthbound_20260818-021941.png"
```

On desktop, dropping a state PNG or `.state` file onto **either** window also
restores it while the app runs. The dropped window gains focus, queued audio is
cleared, and timing restarts without a burst of catch-up frames. Invalid files
are rejected in the terminal and leave the running decompbound state intact.
PNG imports validate the embedded state checksum and ROM hash. Legacy raw
DBST states have no ROM hash. Both v1 and v2 state payloads remain supported.
The source capture is only read; it stays in `~/Pictures/Screenshots/`.

Loading a state also restores its battery SRAM. Normal autosave/exit persists
that SRAM in the selected DS test-save directory. This does not touch the
ordinary player's save directory. State creation, state hotkeys, and native
DRM file-drop events are outside this feature; use `STATE` or the player's
`--load-state:PATH` option on the handheld.

`MONO_RETRO_ROOT` / `MONO_RETRO_PLAYER` select the frontend checkout or binary.
`ROM` selects the user-supplied ROM. Saves default to ignored
`bin/libretro/earthbound-ds-saves/`; override `LIBRETRO_DS_SAVE_DIR` explicitly
to choose another save history. Launching does not migrate or overwrite saves
from the ordinary player. Existing SRAM files use the same 8 KiB format.

The desktop opens independent **Game** and **Party** windows at 512×448 (2×).
Either window accepts normal game keys; closing either exits and persists SRAM.
The existing focus-pause and audio behavior applies to both windows.

For the RG DS Plus, build the AArch64 core as described in
[libretro.md](libretro.md), and build mono-retro's `player-rg-ds-plus` target.
With those artifacts available on the handheld, run the player with its usual
audio configuration and these arguments (substitute the installed paths):

```sh
mono-retro-player-rg-ds-plus \
  --device:rg-ds-plus --earthbound-ds \
  --core:/path/to/decompbound_libretro-arm64.so \
  --rom:/path/to/EarthBound.smc \
  --save-dir:/path/to/earthbound-ds-saves
```

The launcher must release DRM/input ownership before the player runs, as it
does for existing games. Two DRM outputs are required. Use the frontend's
device profile matching the installed kernel: `rg-ds-plus` for the vendor
kernel, or `rg-ds-plus-rocknix` when that profile is present in a player built
with ROCKNIX support. The vendor profile maps DSI-1 to Game and DSI-2 to
Party/touch; the current ROCKNIX kernel exposes the physical panels in the
opposite connector order, so its profile uses DSI-2 for Game and DSI-1 for
Party/touch. The frontend scales each logical 256×224 panel separately.
On 1024×768 displays it selects 3× (768×672), with 128-pixel side borders and
48-pixel top/bottom borders. UI acceptance targets 2× and above; native DS 1×
display accommodation is outside scope.

For a temporary default test state, add `--earthbound-ds` and
`--load-state:/absolute/path/to/capture.png` to the installed Decompbound
wrapper and select a separate `--save-dir`. Remove the state argument to
return to normal boot/save loading; leaving it present reloads the capture on
every launch. Copy private screenstates directly to the device, never through
Git. Keep a backup of the installed wrapper before changing these defaults.
The current device test setup is recorded in [human-verify.md](human-verify.md).

## Controls

| Input | Companion action |
|---|---|
| L2 / R2 | Previous / next character, wrapping once per press |
| Page Up / Page Down | Keyboard equivalents |
| Tap / click a lower status panel | Select that character |

The first touch contact owns the pointer until it ends. Selection happens on
press rather than while dragging. Top-screen and border touches are ignored.
Selecting a character never sends a game command or writes game memory.
Ordinary SNES controls keep working; use the original menus for item use and
battle actions. Hold Select+Start for two seconds to exit on the handheld.

## Core/frontend contract

`decompbound_dual_screen = disabled|enabled` is a startup-only libretro option;
disabled is the default, including when a frontend does not implement options.
Reload the content to change modes. The same shared library supports both.

Default enabled output is one 256×448 frame, with the complete original game
in rows 0–223 and the companion in rows 224–447. Pitch remains 1024 bytes.
Both the negotiated opaque XBGR and standard XRGB8888 transports are supported.
Experimental viewport options change game and combined geometry as described in
[expanded-viewport.md](expanded-viewport.md#desktop-launch-and-transport).
Audio timing, SRAM, WRAM exposure, and normal RetroPad input are unchanged.
RetroPad IDs 12/13 control selection; `RETRO_DEVICE_POINTER` is normalized
against the full combined frame. The frontend transforms bottom-panel input
back through integer scaling and borders before adding the 224-row offset.

Mono-retro's explicit `--earthbound-ds` preset sets this option and validates
the geometry. It is mutually exclusive with the melonDS `--ds-layout` preset;
melonDS retains its existing options, 256×192 panels, and touch behavior.
Other frontends may enable the option and display the combined frame normally.

The core accepts DBST or complete `ebSt` PNG bytes through `retro_unserialize`.
It validates into a temporary machine before restoring the live one in place,
so rejected imports do not partially change CPU, RAM or SRAM. It retains
`retro_serialize_size = 0`: this is an import facility, not state creation.
Mono-retro treats file contents as opaque core-defined bytes, importing startup
state after disk SRAM and before enabling save persistence. Inputs and retained
audio are cleared after successful imports.

Party records and inventory derive from the existing live WRAM layout and
ROM item-table decoder. Fonts and common UI assets are decoded once per ROM
load. Live CGRAM colors preserve the game's palette changes; the renderer
reads WRAM and palette snapshots without changing either. The lower panel
redraws when its data, rolling phase, palette or selection changes. See
[original UI rendering](earthbound-ui.md) for the independently verified
loaders, font formats, icon generation and layout contracts.

Run `make libretro-ui-test` for the original-routine UI oracles, or
`make libretro-ds-test` for those checks plus the core ABI/state tests.

## Party membership and order

Use the counted game/HUD identity array at WRAM `$986F`, with u8 count at
`$98A4`. Preserve that order, cap at its six physical slots, and keep unique
playable IDs 1–4. Known character records alone do not imply membership;
guests are outside this panel's scope.

Original `$C21034` loads IDs at `$C21043` (file `0x021043`) and bounds its
walk by `$98A4` at `$C2107A`. `$C2109F` selects a meter slot from the same
array. The six-slot capacity is explicit in the clear loop at `$C24CC9` /
`$C24CCD` (file `0x024CC9` / `0x024CCD`); `$C229E8` also bounds compaction by
six. Playable identities remain 1=Ness, 2=Paula, 3=Jeff, 4=Poo.

The earlier reader incorrectly scanned seven bytes of `$988B`, a separate
six-slot overworld walking array counted by `$98A3`. Original `$C02D60` /
`$C02D6F` clear its six entries, and `$C03516` consumes them during entity
updates. Byte seven is `$9891[0]`, a parallel attribute read at `$C03565`.
In local `earthbound_20260818-021632.png`, the active HUD list is `[3]`, but
that adjacent attribute equals 2. The old walk therefore invented Paula.

Within the existing persist block `$97F5` → save-slot `+$20`, HUD order maps
to slot `+$9A` (six bytes), count to `+$CF` (one byte). Walking identities are
separately at `+$B6`, with count `+$CE`. Shared live/SRAM readers and the SRAM
inspector use the corrected playable membership; report APIs retain known
character rows with their `inParty` flags, while the DS panel shows only active
members in HUD order.

The ROM-generated meter test verifies displayed order against the identity
actually advanced by original `$C2109F`. It can also verify a local capture
without bundling it:

```sh
nim r -d:release tests/integration_ds_meters.nim "$HOME/Pictures/Screenshots/earthbound_20260818-021632.png" 3
```

Synthetic tests cover a counted solo member with other initialized characters,
stale entries beyond the count, guest filtering across all six slots, adjacent
attributes, reordering, and selection fallback when a member leaves.

## Live meter evidence

Character records start at WRAM `$99CE`, stride `$5F`. HP display is the
unsigned integer word at `+$45`, with its 16.16 fractional word at `+$43`;
its target/settled value is `+$47`. PP uses `+$49` / `+$4B` / `+$4D` in the
same order. Fractional bit zero also gates the original updater. Maxima remain
`+$0A` and `+$0C`.

Original `$C2109F` (file `0x02109F`) selects a displayed member through
`$986F[$0002 & 3]`. HP integer loads/stores include `$C21108` / `$C21164`;
PP includes `$C21247` / `$C21345`. The arithmetic moves the fixed-point display
toward its separate target. The initialization loop copies settled targets
into display words at `$C10A56–$C10A65` (file `0x010A56–0x010A65`), then clears
both fractions. Original call sites for the stepper are `$C12E14` and `$C12E44`.
The game also
consults displayed HP at `$C04FCC` and `$C05140`; these are different fields
from the settled values exposed by the existing party reader.

`tests/integration_ds_meters.nim` builds isolated machines from the user's ROM
and generated WRAM, then calls the original `$C2109F` through our assembler and
CPU. It tests damage, healing, PP spending/recovery and HP reaching zero for
all four playable identities. The original fast-meter flag `$9698=1` supplies
a bounded convergence path; this does not claim to explain every normal-speed
rate or ailment rule. No real save-state is a fixture.

The full loop first skips updates when `$9697` is nonzero. With `$9698=0`, it
tests bit zero of the HP/PP fraction before stepping; differing integer and
target values arm that bit at `$C21216` / `$C21353`. The fractions are fixed-point
data with an embedded gate, not simple boolean flags. Rate computation remains
the original engine's responsibility. The special unconscious path at
`$C05140` and all status/ailment encodings are not reimplemented by this UI.

The companion uses display words during the existing mode-0 battle view with
a playable pointer in `$4DC8`. Elsewhere it uses settled values, since display
words can remain stale while the battle HUD is inactive. Tests explicitly
distinguish a pending fatal target of zero from a positive rolling display,
and verify switching back to settled values outside battle. Physical scene
transitions and visual agreement remain human checks.

## Verification

```sh
make libretro-ds-test
nim r -d:release tests/integration_libretro.nim
nim r -d:release tests/integration_ds_meters.nim
make libretro-frontend-test
make compare
```

The ROM parity test exercises both ordinary and dual modes over 1,200 frames
each, comparing every top-screen pixel, PCM sample, WRAM byte and SRAM byte.
Synthetic tests cover roster initialization/order, all inventory slots,
equipment indices, large numeric values, input edges and selection changes.
The independent C host checks negotiation, reset and library lifecycle in both
modes. Real ROMs, captures, SRAM and game-derived test outputs stay local and
ignored.

The state-import unit test generates its own tiny program and machine state;
it checks raw/PNG/v1 restore, bad versions, truncation, trailing bytes, CRC/hash
errors, and rejection without changing live RAM/SRAM. To compare a local
screenstate against the existing emulator through the actual core:

```sh
nim r -d:release tests/integration_libretro.nim "$HOME/Pictures/Screenshots/earthbound_20260818-021941.png"
```

Mono-retro's player tests cover the two geometries, integer scaling and pointer
mapping. Its X11 integration runs on an isolated Xvfb display, including both
EarthBound DS windows, resize, keyboard triggers, pointer routing, focus pause,
and either-window shutdown. Physical acceptance remains in
[human-verify.md](human-verify.md).
