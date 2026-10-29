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
DECOMPBOUND_TARGET=arm64 nim c src/libretro/core.nim
```

`DECOMPBOUND_CC` selects the compiler (default `aarch64-unknown-linux-gnu-gcc`).
The output is `bin/libretro/decompbound_libretro-arm64.so`; the desktop core is
preserved. With Nix's cross compiler, set `NIX_DONT_SET_RPATH=1` and
`NIX_DONT_SET_RPATH_aarch64_unknown_linux_gnu=1` to omit store-specific runpaths.
The ARM core retains runtime checks and the same frontend contract.

## Frontend contract

The core exports the standard [libretro v1 functions](https://docs.libretro.com/development/cores/developing-cores/), with C calling conventions.
It loads frontend-provided ROM bytes (`need_fullpath = false`): a 3 MiB US
EarthBound image, optionally preceded by a 512-byte copier header. The core
copies those bytes and needs no BIOS or extracted assets. A missing ROM or
unsupported pixel format is rejected through the API and optional frontend log.

| Interface | Value |
|---|---|
| Video | 256x224, XRGB8888 (`0x00RRGGBB` words), 1,024-byte pitch |
| Aspect | 8:7 square pixels, matching the existing desktop player |
| Timing | 60 frames/sec, 533 stereo samples/frame, 31,980 samples/sec |
| Audio | Interleaved signed 16-bit stereo; batch callback preferred, per-sample fallback |
| Input | Port 0 RetroPad: B, Y, Select, Start, Up, Down, Left, Right, A, X, L, R |
| Save RAM | `RETRO_MEMORY_SAVE_RAM`: 8,192 bytes |
| Work RAM | `RETRO_MEMORY_SYSTEM_RAM`: 131,072 bytes |

The sample rate describes the existing replay cadence exactly. Frontends should
resample from the advertised rate when their audio device requires another rate.
Discarding audio never changes the emulation rate. The frontend owns pacing;
there are no sleeps or window/event loops inside the core.

Pixel and PCM buffers remain core-owned; a frontend retaining output should copy
it during the callback. SRAM and WRAM pointers remain stable until game unload.
The frontend loads and persists SRAM, using the same raw 8 KiB layout as the
existing player. Reset preserves SRAM. The core performs no save-file I/O.

State creation, cheats, special-content loading, other controller ports, and
hardware rendering are unsupported. Serialization reports size zero and returns
false. Explicit `retro_unserialize` imports accept the existing DBST v1/v2
format or complete F12 PNGs with an `ebSt` chunk, including ROM-hash validation
for PNGs. The legacy snapshot format is unchanged. The ABI is single-instance
and used on the frontend's emulation thread.

Target-local Nim settings keep runtime checks enabled, prefix the Nim runtime
entrypoints, and export only `retro_*`. Library allocations use libc allocation
with ORC reference cleanup: a private Nim allocator otherwise retains heap pages
across library unloads. Lifecycle tests retain the memory-growth check.

## Verification

```sh
make libretro-test
nim r -d:release tests/integration_libretro.nim
make compare
```

The unit test runs independent C and Nim hosts against the actual shared library.
It checks the exported ABI, native dependencies, synthetic ROM/header loading,
controller mapping, video colors and blanking, audio callback modes, SRAM,
reinitialization, and repeated `dlopen`/`dlclose` with bounded memory growth.
The integration test requires the user's ROM and compares 1,200 cold-boot frames
with the headless emulator: every pixel, PCM sample, WRAM byte, and SRAM byte.
It switches between batch, per-sample, and discarded audio during that run.

`make test` builds the library before the unit suite. `make integration-test`
also builds it before the ROM-dependent suite. The existing replay goldens
remain independent and are checked with `make bench-check`.

## Mono-retro

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
