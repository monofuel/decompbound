# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Filed: 2026-07-04

---

## 1. Giygas "red snow" intro shows the wrong animation phase

**Status:** OPEN — compositor fixed, animation fidelity remains.

The intro before the "THE WAR AGAINST GIYGAS!" title card should show **red
TV snow** — incoherent churning static with red mixed in (the *end* of the
Giygas death animation). We instead render a **coherent, recognizable Giygas
face** that cycles colors — the *early/structured* phase, not the snow.

The color-math compositor is correct now (BG1 face main + BG2 noise subscreen,
HDMA-scrolled per scanline, CGADSUB=03 / CGWSEL=02). The remaining problem is
**timing fidelity**: the snow is *motion*, not a graphic. The game re-seeds the
noise source every frame in its NMI handler ~60x/s; if that per-frame churn
doesn't advance at the right rate we get a slowly-drifting face instead of
fast snow. Full detail + investigation leads in [red-snow.md](red-snow.md).

**Scope:** core-emulator timing (claude-code).

---

## 2. "Characters walking around the world" intro sequence is static/glitchy

**Status:** OPEN.

The overworld intro (camera circling the party at Summers, characters walking)
is broken in several ways:

- It does **not** show the characters walking.
- It **does** show 2 glitchy sprites (wrong tiles / wrong position).
- It only shows the **initial frame at Summers** — nothing after that animates.
- The camera does **not** do its "circle" pan around the players.
- No animations play at all — the scene is frozen on frame 1.

This smells like the same **per-frame update not advancing** root cause as
issue #1: the game's NMI-driven logic (sprite OAM updates, scroll/camera
writes, animation frame counters) isn't running frame-to-frame. If the scene
is frozen on its first frame, the game's main loop / NMI cadence likely isn't
churning the OAM + scroll registers each frame.

**Investigation leads:**
- Confirm whether *anything* advances frame-to-frame in `make play` here
  (F12 two frames apart, diff the PNGs) — is the whole scene frozen or just
  the sprites?
- Trace what writes OAM during this scene: are sprite positions/tiles being
  updated each frame, or written once and never again?
- Check the camera: is the game writing BG scroll registers ($210D-$2114)
  each frame? If the scroll latch isn't advancing, the camera can't pan.
- The 2 glitchy sprites suggest an OAM decode or sprite-table base issue —
  verify against the OBSEL/name-base handling (the earlier table-1 precedence
  bug may have a sibling here).

**Scope:** core-emulator timing + sprite/OAM (claude-code).

---

## 3. Game menu renders background but not the menu itself

**Status:** OPEN.

The in-game menu's **checkerboard background renders correctly**, but the
**menu box / text on top of it does not render**. So one layer composites and
the other doesn't.

This points at a **specific BG layer or window** not making it into the
composite:
- The menu text/box is likely on a different BG layer (or uses a window mask)
  than the checkerboard. If that layer isn't in the main-screen mask (TM/$2C)
  or is being masked out by a window, it won't show.
- Could also be a tilemap/char base pointing at the wrong VRAM address for the
  menu layer, or the layer being force-blanked/disabled.

**Investigation leads:**
- Dump TM/$2C and TS/$2D during the menu — which BG layers are enabled?
- Check the window registers (W12SEL/W34SEL/WOBJSEL, WH0-WH3, TMW/TSW) — is a
  window clipping the menu layer out?
- Verify the menu layer's tilemap + char base addresses point at real menu
  data in VRAM (not stale/zero).
- Check BG priority: is the menu on a layer that's being drawn *behind* the
  checkerboard and losing the priority test?

**Scope:** core-emulator PPU layers/windows (claude-code).

---

## 4. No music or sound effects play

**Status:** OPEN.

Nothing audible currently plays — no BGM, no SFX. The APU handshake / SPC700 +
S-DSP path exists and is vector-accurate, but the rendered audio isn't reaching
the speakers in `make play`.

**Plan:** wire playback through **treeform/slappy** (already a documented
dependency, see [audio.md](audio.md) — the "easy slappy example tools" path).
The S-DSP mixes 8 BRR voices into a PCM buffer; slappy is the simplest route
to actually push that buffer to the host audio device from the play loop.

**Investigation leads:**
- Confirm the S-DSP is producing non-silent PCM at all (dump a buffer to WAV
  from the play loop and inspect — the music_explore tool already touches
  this path).
- Is the APU handshake completing so the game uploads its song/SFX data? If
  the HLE handshake stalls, the SPC never gets its sequence data and stays
  silent.
- Wire a slappy audio sink into `play.nim`: pull the S-DSP output buffer each
  frame and feed it to slappy for real-time playback.
- Start with BGM (proves the SPC700 sequencer + DSP mixing end-to-end), then
  SFX.

**Scope:** audio pipeline + slappy integration. Good candidate to spec as a
grok ticket once the S-DSP-produces-PCM question is answered, since the slappy
wiring is mechanical; the "is it silent and why" diagnosis stays with claude.

---

## Common thread

Issues #1 and #2 (and possibly the animated parts of others) share a likely
root cause: **per-frame game logic isn't advancing at the right rate**. Our
synthetic NMI cadence + HLE-APU timing may not give the game's main loop the
instruction budget it expects per frame, so frame counters / RNG / OAM updates
stall. Fixing frame-accuracy once should sharpen several of these at once.
