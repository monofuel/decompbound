# Goal: decompbound on a Raspberry Pi game system

**Status:** NOT STARTED. Aspirational platform target.

Run `make play` on a Raspberry Pi — ideally launched from an existing Pi game
system (RetroPie / EmulationStation style box) so EarthBound-on-our-emulator
sits in the same menu as everything else. The Pi is aarch64 and Nim compiles
there fine, so this is a **porting + performance** goal, not a rewrite.

This target also shapes one earlier decision: it's why the LLM-plays harness
links Lua **statically** (see `docs/llm-plays.md`) — a self-contained binary is
what you want to drop onto a Pi without chasing system libraries.

## What already helps

- **Nim + aarch64** — the compiler and our pure-Nim cores (CPU, PPU, SPC700,
  bus) build on ARM with no code changes; it's C under the hood.
- **Input is a natural fit** — the player already uses **paddy** (evdev
  gamepads), and Pi game systems are gamepad-first. Controllers should Just
  Work, which is more than can be said for the graphics path.
- **Audio** — slappy → openal-soft runs on the Pi over ALSA.

## The real blockers (in rough order of pain)

### 1. Graphics: desktop GL → GLES

The single biggest port issue. Our GL path targets **desktop OpenGL** — e.g.
`music_explore.nim` compiles `#version 410` shaders, and the player blits its
frame through a desktop-GL textured quad. A Raspberry Pi's Mesa stack is
**OpenGL ES** (GLES 2/3) + limited desktop GL; `#version 410` shaders won't
compile. Options:

- Port the blit to **GLES-compatible** shaders (`#version 300 es` / `100`) and
  a GLES context — the frame output is just a full-screen textured quad, so the
  shader surface area is tiny.
- Or bypass GL for the final blit entirely (KMS/DRM framebuffer, or SDL) since
  all we do is push one `frameImage` per frame — we don't need a 3D pipeline.

Whichever we pick, windy must be able to give us a GLES (or framebuffer)
context on the Pi. Worth a spike to confirm windy's Pi story before committing.

### 2. Performance: the interpreter budget

The emulator is a straightforward per-instruction 65816 interpreter + a
software per-scanline PPU compositor + a live SPC700, none of it tuned for
speed. A **Pi 4/5** has the headroom (real SNES emulation is well within its
CPU budget), but our unoptimized interpreter may need help to hit full frame
rate:

- Build with `-d:release` (and try `-d:danger` for the hot loops once correct).
- Profile the CPU step + PPU scanline compositor; those dominate.
- Older/tiny Pis (Zero, armv6) are likely out of scope — target Pi 4/5.

### 3. Packaging & integration

- A reproducible aarch64 build (nix can target aarch64, or cross-compile).
- An **EmulationStation "port" entry** so decompbound launches from the game
  menu with a controller, no keyboard — the whole point of a Pi game box.
- Bundle the assets/paths the player expects (ROM path, `.srm` location) in a
  Pi-friendly layout.

## Definition of done

- [ ] `make play` (or a packaged binary) runs EarthBound at playable frame rate
      on a Pi 4/5, rendering via GLES or a framebuffer path.
- [ ] A paddy gamepad drives it with no keyboard attached.
- [ ] Audio plays through the Pi's ALSA/openal-soft.
- [ ] Bonus: launchable as a "port" from EmulationStation on your Pi game box.

## Non-goals

- Tiny/old Pis (Zero, armv6) — target Pi 4/5.
- Bit-perfect timing beyond what stays playable on ARM.

**Scope:** platform port — GLES/framebuffer render path + performance tuning +
aarch64 packaging. Parallel-safe; off the `docs/goal.md` critical path.
</content>
