# Libretro core

Build the Linux x86-64 software core from the repository root:

```sh
make libretro
```

The output is `bin/libretro/decompbound_libretro.so`. It uses the existing Nim
dependencies and standard Linux runtime libraries; it does not link Windy,
Paddy, X11, OpenGL, OpenAL, ALSA, Lua, or MCP. Native device support belongs to
the frontend. The existing desktop player and ROM rebuild remain separate.

For an AArch64 Linux handheld, put the cross compiler on PATH and run:

```sh
DECOMPBOUND_TARGET=arm64 nim c --nimcache:bin/nimcache/libretro-arm64 src/libretro/core.nim
```

`DECOMPBOUND_CC` selects the compiler (default `aarch64-unknown-linux-gnu-gcc`).
The output is `bin/libretro/decompbound_libretro-arm64.so`; the desktop core is
preserved. With Nix's cross compiler, set `NIX_DONT_SET_RPATH=1` and
`NIX_DONT_SET_RPATH_aarch64_unknown_linux_gnu=1` to omit store-specific runpaths.
Keep the ARM cache separate from desktop/profile builds to avoid mixing target
object files when building concurrently.
Desktop and ARM cores use the shipping profile by default (`danger`, with
compiler runtime checks disabled). Use `nim c -d:debug src/libretro/core.nim`
for a checked developer build; the same selection applies to the ARM command.
The frontend contract and explicit ROM/state validation are unchanged.

Core-side profiling, optimization ideas and threading tradeoffs are collected
in [Libretro core performance](libretro-performance.md).

The libretro core batches the verified EarthBound event-wait loop inside each
existing CPU instruction budget. It requires the original bus/hooks, unchanged
instruction bytes, byte-width WRAM polling and no pending interrupt. Other
execution falls back to ordinary interpretation. Scanline, NMI, HDMA and audio
scheduling are unchanged; generic frame/replay callers remain ordinary unless
they explicitly supply a polling context. Reset/state import retain the
context, and unload clears it before releasing machine hooks.

For a shipping control build with batching disabled:

```sh
nim c -d:disableCpuPollingBatching -o:bin/libretro/polling-control.so src/libretro/core.nim
```

There is no new frontend option, libretro ABI entrypoint or save-state format.

## Frontend contract

The core exports the standard [libretro v1 functions](https://docs.libretro.com/development/cores/developing-cores/), with C calling conventions.
It loads frontend-provided ROM bytes (`need_fullpath = false`): a 3 MiB US
EarthBound image, optionally preceded by a 512-byte copier header. The core
copies those bytes and needs no BIOS or extracted assets. A missing ROM or
unsupported pixel format is rejected through the API and optional frontend log.

| Interface | Value |
|---|---|
| Video | Default 256x224, standard XRGB8888 or negotiated opaque XBGR, 1,024-byte pitch |
| Aspect | Square pixels; default 8:7, matching the existing desktop player |
| Timing | 60 frames/sec, 533 stereo samples/frame, 31,980 samples/sec |
| Audio | Interleaved signed 16-bit stereo; batch callback preferred, per-sample fallback |
| Input | Port 0 RetroPad: B, Y, Select, Start, Up, Down, Left, Right, A, X, L, R |
| Save RAM | `RETRO_MEMORY_SAVE_RAM`: 8,192 bytes |
| Work RAM | `RETRO_MEMORY_SYSTEM_RAM`: 131,072 bytes |

The sample rate describes the existing replay cadence exactly. Frontends should
resample from the advertised rate when their audio device requires another rate.
Discarding audio never changes the emulation rate. The frontend owns pacing;
there are no sleeps or window/event loops inside the core.

Startup-only experimental width/height options can enlarge the game viewport.
The default output is unchanged; custom dimensions determine geometry and pitch.
Dual-screen mode retains the 256×224 companion with a separate crop below the
game. See [expanded viewport](expanded-viewport.md#desktop-launch-and-transport)
for options, dimensions and the desktop prototype's supported scene coverage.

Pixel and PCM buffers remain core-owned; a frontend retaining output should copy
it during the callback. SRAM and WRAM pointers remain stable until game unload.
The frontend loads and persists SRAM, using the same raw 8 KiB layout as the
existing player. Reset preserves SRAM. The core performs no save-file I/O.

During each content load, the core first offers mono-retro's optional private
transport: environment command `0x00024D52`, with a pointer to native `uint32`
FourCC `0x34324258` (`XB24`). If accepted, video contains opaque **R,G,B,255**
bytes copied unchanged from Pixie. The game image and optional companion image
are copied into the persistent combined buffer, with the game above the companion.
There is no per-pixel channel conversion on this path. Rendered output is opaque,
including forced blanking; the frontend must copy borrowed rows before returning.

Rejection falls back to standard environment command `10`, format `1`, with
the existing `0x00RRGGBB` packing. If both requests fail, content loading fails.
The private FourCC is separate from the standard enum and is never passed to
command `10`. A successful load logs the selected path once; reset and state
import retain it, while unload/deinit clear it and the next load negotiates again.
The private path requires an updated mono-retro-player; older frontends continue
through XRGB8888. See mono-retro's `docs/libretro-extensions.md` for its complete
little-endian transport contract.

State creation, cheats, special-content loading, other controller ports, and
hardware rendering are unsupported. Serialization reports size zero and returns
false. Explicit `retro_unserialize` imports accept the existing DBST v1/v2
format or complete F12 PNGs with an `ebSt` chunk, including ROM-hash validation
for PNGs. The legacy snapshot format is unchanged. The ABI is single-instance
and used on the frontend's emulation thread.

Target-local Nim settings inherit the root build profile, prefix the Nim runtime
entrypoints, and export only `retro_*`. Library allocations use libc allocation
with ORC reference cleanup: a private Nim allocator otherwise retains heap pages
across library unloads. Lifecycle tests retain the memory-growth check.

## Verification

Agent-run checks must use muted/null audio by default. Audible device playback
requires monofuel's explicit, immediate permission for that specific run, as
specified in `AGENTS.md`. PCM parity checks do not require speaker output.

```sh
make libretro-test
nim r -d:release tests/integration_libretro.nim
make compare
```

The unit test runs independent C and Nim hosts against the actual shared library.
It checks the exported ABI, native dependencies, synthetic ROM/header loading,
controller mapping, both pixel transports, opaque filler bytes, colors and blanking,
negotiation rejection/fallback, audio callback modes, SRAM,
reinitialization, and repeated `dlopen`/`dlclose` with bounded memory growth.
The integration test requires the user's ROM and compares 1,200 cold-boot frames
with the headless emulator in both screen modes and transports: every normalized
RGB pixel, private opaque filler byte, PCM sample, WRAM byte, and SRAM byte.
It switches between batch, per-sample, and discarded audio during that run.
`make libretro-test` also compares polling batches against original instructions,
including custom-hook fallback and NMI stack state. The optional private-capture
sweep is `nim r -d:debug --opt:speed tests/polling/corpus.nim`; it reads local
captures and writes only a text report beneath ignored `bin/polling/`.

Palette tests and renderer-comparison negative controls also run through
`make libretro-test`. For a renderer change, compile the identical
`tests/ppu/worker.nim` against reference and candidate source trees, using
`-d:danger --mm:orc -d:useMalloc` and separate caches/output paths for both.
Then run `nim r tests/ppu/corpus.nim REFERENCE_WORKER CANDIDATE_WORKER`.
The optional private sweep compares every pixel, PCM byte, serialized CPU/machine
state byte and handshake marker for three frames per capture. It streams data
through pipes, keeps only text under ignored `bin/ppu-palette/`, and bounds each
worker's lifetime with the system `timeout` utility. It does not open audio or
display devices. Both workers must really import their respective renderer;
the older CPU-polling sweep alone cannot validate two renderer versions.

The replay benchmark's `--cpu-poll-batching` option exercises the optimized path
against existing full-tape goldens. Its default remains ordinary interpretation;
do not mistake a default benchmark run for optimization coverage. Batching cannot
be combined with `--write-ref` or `--accept-image`.

`make test` builds the library before the unit suite. `make integration-test`
also builds it before the ROM-dependent suite. The existing replay goldens
remain independent and are checked with `make bench-check`.

## Mono-retro

### RetroAchievements frontend integration

The core advertises libretro `SET_SUPPORT_ACHIEVEMENTS` (`42 | 0x10000`) and
exports the RAM/SRAM sizes listed above. Achievement authentication, ROM hashing,
evaluation and UI belong to mono-retro-player; the core does not link the SDK or
contact the service. The frontend's Decompbound integration uses the SDK's SNES
memory mapper with system RAM and save RAM, and hashes a retained copy of the
original ROM bytes without patching them. It supports Casual achievements only.

The matching frontend adds unlock popups and a paused browser
(F1 / Menu / Home; B / Escape goes back). It defaults to achievements enabled
when configured; `--achievements:off` disables evaluation. Use `mono-retro-ra login`
to create the private `~/.mono-retro-ra.json` token file; root launch wrappers
must pass the intended `--ra-config:/absolute/path` explicitly to the player.
See mono-retro's `docs/retroachievements.md` for setup, controls and network limits.

Legacy state imports keep their existing format. After a successful import, the
frontend resets SDK progress deltas and refreshes memory pointers; rejection
preserves achievement progress. Core, synthetic SDK and desktop integration gates
pass; real-account and handheld acceptance remain on the human verification list.

### Gameplay and state imports

The optional [EarthBound DS companion](earthbound-ds.md) adds a live party and
inventory screen through the same core. Use `make libretro-ds-play` with the
matching mono-retro-player branch; ordinary mode remains the default.

Both launch targets accept `STATE=/absolute/path/to/state.png` (or `.state`).
The matching frontend also accepts state files dropped onto either desktop
window. This restores captured SRAM into the selected test-save history;
the original state file is never rewritten. The handheld uses the startup
`--load-state:PATH` option.

The optional headless compatibility test uses mono-retro's actual loader and
save handling without editing its checkout or opening a display/audio device:

```sh
make libretro-frontend-test
```

It requires the user's ROM, runs 120 frames, and checks SRAM persistence through
an isolated temporary save directory. `MONO_RETRO_ROOT` adds only a source search
path for this test; it is not a dependency of the shipped core. The Makefile
finds a sibling `../mono-retro` checkout or the shared checkout at
`/mnt/steel-chest/Monolab/Home/racha/src/mono-retro`. Override `MONO_RETRO_ROOT`
for a different location.

For a visual test, build mono-retro's desktop player using that project's
instructions, then run from the decompbound repository:

```sh
make libretro-play
```

This rebuilds the core and starts the existing frontend binary with the ROM
selected by `ROM`. Test saves go to ignored `bin/libretro/frontend-saves/`,
separate from the ordinary player's battery save. It does not rebuild or edit
mono-retro. `MONO_RETRO_PLAYER` selects another frontend executable and
`LIBRETRO_SAVE_DIR` selects another save directory. To stop after ten seconds
of emulation:

```sh
make libretro-play MONO_RETRO_ARGS=--frames:600
```

The player pauses while unfocused; click its window if frames stop advancing.
Arrow keys control the D-pad, X/Z are A/B, Enter is Start, Backspace is Select,
and Escape closes the player and persists SRAM.

Use a gamepad for all twelve SNES buttons; the current frontend keyboard layout
does not bind SNES X/Y. Audio and mute options follow the installed frontend
build; consult its `--help`. On the RG DS Plus, the mono-retro menu's Decompbound
entry runs the ARM core with a separate device save directory. It starts on the
bottom screen; L2 switches screens, and holding Select+Start for two seconds
returns to the menu. Physical-device acceptance is tracked in `human-verify.md`.

The full mono-retro X11 integration test also accepts this core and ROM as its
two arguments. From the mono-retro checkout, with an isolated Xvfb running:

```sh
MONO_RETRO_TEST_DISPLAY=:97 ALSOFT_DRIVERS=null build/integration-player-x11 \
  /absolute/path/to/decompbound/bin/libretro/decompbound_libretro.so \
  '/absolute/path/to/decompbound/bin/Earthbound (U) [!].smc'
```

Use an unused test display, never the desktop display. Mono-retro's
`README-player.md` describes building this test and its fixture core. It checks
window rendering, resize, input, focus pause, and clean exits against the fixture,
then runs 180 paced frames with the real decompbound core and verifies an SRAM
file. The null audio driver avoids speaker output during automated tests.

ROMs, SRAM, screenshots, and machine states remain local and ignored. Human
acceptance checks are in [human-verify.md](human-verify.md).
