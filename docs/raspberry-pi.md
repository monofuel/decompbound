# Goal: decompbound on a Raspberry Pi game system

**Status (2026-09-19): headless emulator at full speed on a Pi 3; player port
written, awaiting its first run on the handheld.**

Target: `gammapi`, monofuel's 2018 3D-printed Pi 3A+ portable (BCM2837,
4× Cortex-A53 @ 1.4 GHz, 512 MB, 320x240 Adafruit PiTFT on the ili9341 DRM
driver shown by the labwc compositor, X11 apps via Xwayland, 19 case buttons as
a gpio-keys keyboard, EmulationStation menu). Dev/verify box: the `ember`
cluster, four Pi 3B (same SoC @ 1.2 GHz, 1 GB, Gentoo, Nim 2.2.4 + nimby
packages on each node, shared NFS checkout at `/mnt/ember/scratch/decompbound`).
Ember runs glibc 2.42 and has no GL/X11/OpenAL, so it does headless work only;
**the player binary is built on gammapi itself** (Bookworm, glibc 2.36).

## Measured

Fixed workload = `bench_replay` on the human-verified sunrise tape
`20260816-223148`, first 3600 frames (60 s of game), rendering on, hashes
compared to the x86 goldens (`ref OK` on every row).

| build | ember-1/2 (A53 @ 1.2 GHz) | 7950X |
|---|---|---|
| master before this work, `-d:release` | 232 s (0.26×) | 9.5 s |
| `-d:danger` only (`--mm:arc`, `-d:lto` were noise) | 132 s (0.45×) | |
| + PPU tile-run decode, static layer tables, direct pixel writes, sprite clipping | | 6.4 s |
| + CPU enum jump-table dispatch, inline flat-memory bus fast paths, const DMA patterns | 61 s (0.98×) | 5.0 s |
| + each BG decoded once per scanline, ladder split from the recorded priority bit | 59 s (1.02×) | 4.6 s |
| + CGRAM palette cache | **56.7 s (1.06×)** | 4.5 s |

gammapi's 1.4 GHz clock should land near 49 s (1.2×). Peak RSS headless is
30 MB; RAM is not a constraint. CPU-only cost (`--no-render`) is ~40 % of the
frame; the PPU scanline compositor is the rest, DSP mixing under 5 %.

## How the referee works

Every optimization above is proven behaviour-preserving by
`src/tools/bench_replay.nim` (see [input-replay.md](input-replay.md)): replay a
tape from its pinned start state, fold a crc32 of each rendered frame and of the
533 APU samples per frame into running hashes, compare a row every 60 frames
against the tape's `.ref` golden in `decompbound_secret`. The hot path is
integer-only, so arm64 must reproduce the x86 hashes exactly; a `MISMATCH` on
ember is a bug, not noise. Goldens were written by the pre-optimization tool
commit (`ec60278`) and never regenerated during the work.

## Ember workflow

```
scripts/ember_bench.sh <variant> "<extra nim flags>" [tape] [frames]
```

Run from `/mnt/ember/scratch/decompbound` on a node. Builds to `~/bench/`
(local nimcache, so four nodes build concurrently from the NFS checkout), runs
the fixed workload twice, appends to `/mnt/ember/scratch/bench/results.<host>.tsv`
and records SoC temperature and the CPU clock 15 s into each run (schedutil
idles to 600-900 MHz between runs; a throttled run is not a benchmark).
Fan out from a workstation with `ssh … scripts/ember_bench.sh … &` per node.
`make bench` / `make bench-check` / `make bench-ref` are the same tool on any
host. Nim on a node: `nimby` (`nimby-Linux-ARM64` release) + `nimby use 2.2.4`
(prebuilt arm64 compiler) + `nimby sync -g nimby.lock` in the checkout.

## Build flags

`-d:fast` (root `config.nims`) implies `-d:danger`: bounds, range and overflow
checks off. It is the shipping/benchmark profile; the referee build and the
tests stay `-d:release` so a hidden out-of-range access still raises there.
`--mm:arc` and `-d:lto` measured within noise on the A53 and are not used.

## Player port (`--kiosk`)

Blockers from the original plan and what happened to them:

1. **Graphics.** `src/tools/glblit.nim` now targets OpenGL 2.1 (GLSL 1.20,
   explicit attribute locations, no VAOs, unsized `GL_RGBA`, one
   `glTexImage2D` then `glTexSubImage2D` per frame) and `play.nim` uses it
   instead of its own copy. windy's X11 backend creates a legacy GLX context
   (it ignores `openglVersion`), which on the Pi is Mesa's 2.1 compat context
   over Xwayland, the same path RetroArch uses on the panel. The viewport is
   integer-scaled and centred: 1× (256x224) on the 320x240 panel, 3× on the
   desktop window.
2. **Input.** gammapi's buttons are a keyboard: arrows, `x`=A, `z`=B, `s`=X,
   `a`=Y, `q`=L1, `w`=R1, `e`=L2, `r`=R2, Enter=Start, RShift=Select, and the
   five screen-edge buttons F1 / Esc / F2 / F4 / Space (left to right:
   Space, F4, F2, Esc, F1). play.nim already keyed the pad this way; R now
   accepts W or E. F1 = screenstate, F2 / F4 = save / load slot 1, Space =
   pause, **Esc held for a second = clean exit** (SRAM flush, end.state).
3. **Audio.** slappy → OpenAL → ALSA default → pipewire-pulse on Bookworm.
   `--no-audio` is the fallback; `ALSOFT_DRIVERS=pulse` in the launcher if
   silent.
4. **Pacing.** `--no-vsync` paces by the wall clock and sleeps when no frame
   was emulated; with vsync the swap blocks as before.
5. **Packaging.** `make release-play` → `bin/decompbound-play` (`-d:fast`),
   built on gammapi. All save/log paths in play.nim are cwd-relative, so the
   install is a directory:

```
~/decompbound/
  decompbound-play
  bin/Earthbound (U) [!].smc     # .srm lands beside it
  bin/states/                     # F2/F4 slot 1
  captures/sessions/<stamp>/      # --kiosk replays + F12s (never into a repo)
```

Launcher `~/RetroPie/roms/ports/decompbound.sh`:

```bash
#!/bin/bash
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
cd "$HOME/decompbound" || exit 1
exec ./decompbound-play --kiosk "bin/Earthbound (U) [!].smc" >> play_stdout.log 2>&1
```

and a `ports` system in `~/.emulationstation/es_systems.cfg` with
`<command>bash %ROM%</command>` (no runcommand, no tty needed).

`scripts/gammapi_setup.sh` does all of the above on the device (idempotent).
By hand, the prerequisites are: nimby + Nim 2.2.4 as on ember, `nimby sync -g nimby.lock`,
and `libopenal-dev libevdev-dev libudev-dev libgl-dev libx11-dev libxext-dev
libxcursor-dev` (runtime: `libopenal1 libevdev2 libudev1 libgl1 libx11-6
libxext6 libxcursor1`; RetroArch already pulled most of them).

## Definition of done

- [x] Headless emulator ≥ 1.0× realtime on a Pi 3 (ember-2: 1.06×), hashes
      equal to the x86 goldens.
- [ ] `decompbound-play --kiosk` runs fullscreen at 1× on gammapi from
      EmulationStation ([human-verify.md](human-verify.md) rows dated 2026-09-19).
- [ ] Every case button drives it; audio plays through PipeWire.
- [ ] The fixed workload timed on gammapi itself.

## Non-goals

- Pi Zero / armv6.
- Threading the APU onto a second core: designed ("APU one scanline behind",
  joins on every `$214x` access) but not needed once single-thread reached 1.06×.
- Bit-perfect timing beyond what stays playable.
