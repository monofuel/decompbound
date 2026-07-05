# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Filed: 2026-07-04

**Status summary (2026-07-04):**
- #1 red static — OPEN, diagnosis corrected (wrong animation *segment*).
- #2 overworld intro — OPEN, budget hypothesis disproven; input/demo path.
- #3 menu box — **FIXED** (BG3 priority).
- #4 no audio — **FIXED** (live APU streaming via slappy).

---

## 1. Giygas "red snow" intro shows the wrong part of the animation

**Status:** OPEN — diagnosis corrected; needs an animation-data dig.

There is ONE Giygas death animation: **swirl -> random red/black/white TV
snow**. End-game shows the full progression. The intro deliberately shows
**only the snow tail** (the game hides that the snow IS Giygas until the very
end — the beginning is secretly the ending). We render the **swirl start**
instead: the wrong slice of the animation, spoiling the reveal.

Confirmed (frame sweep 1300-1920): the effect **churns** (animates) but shows
the swirl the whole window; it never shows the snow. **Budget is NOT the
cause** — a ~6x instructions-per-frame bump did not change what is shown. So
this is **wrong-animation-segment selection**, not the compositor and not raw
timing. Full detail + investigation leads in [red-snow.md](red-snow.md).

**Scope:** core-emulator reverse engineering — how EB indexes/streams the
death-animation frames for the intro vs. end-game (claude-code).

---

## 2. "Characters walking around the world" intro is static

**Status:** OPEN — budget disproven; movement-input path suspected.

The overworld attract scene (camera circling the party at Summers, characters
walking) renders cleanly but does not move:

- Characters do **not** walk; the camera does **not** pan/circle.
- Background is **byte-identical across thousands of frames** (zero scroll).
- Sprite *appearance* does cycle (blonde -> red-capped), so the display
  pipeline and per-frame animation run — the scene is NOT frozen/crashed.

**Budget hypothesis DISPROVEN:** rendered the scene at a realistic
instructions-per-frame budget (IPL=180, ~23k/frame vs the default ~7.8k) —
the camera *still* did not pan and characters *still* did not move. So
per-frame starvation is not the cause.

The camera follows the player, so both freezing collapses to one question:
**why doesn't the (demo-driven) player move?** Most likely the attract demo's
recorded input isn't reaching the movement code (input edge handling, demo
input read, or the always-on $4218 auto-joypad read clobbering injected
input).

**Investigation leads:**
- Trace the player-position WRAM variable across frames — static or moving?
- Find where EB reads controller input during attract and whether the demo
  feeds it; check if our auto-joypad read overwrites demo input.
- The "2 glitchy sprites" note: verify OAM decode / sprite-table base once the
  motion path is understood.

**Scope:** core-emulator input/demo + sprite/OAM (claude-code).

---

## 3. Game menu renders background but not the menu box  — FIXED

**Status:** **FIXED** (2026-07-04).

**Confirmed root cause:** the file-select menu is Mode 1 with the **BG3
priority bit** ($2105 bit 3) set. The menu window/text lives on **BG3** (954
nonzero tilemap entries, 494 with the per-tile priority bit); the checkerboard
is opaque **BG2**. Our compositor drew BG3 at the *back*, so the opaque BG2
checkerboard painted right over the menu. Proven by isolating layers: BG3
alone = the menu box; BG2 alone = the checkerboard.

**Fix:** `ppu.nim` now honors per-tile priority. `bgScanlineInto` takes a
priority filter (all / low-only / high-only via tilemap bit 0x2000), and in
Mode 1 with the BG3-priority bit set, BG3 is split: low-priority tiles stay at
the back, **high-priority BG3 tiles draw in front of BG1/BG2**. Verified: the
menu window now renders over the checkerboard; war-card and overworld frames
unchanged; `make test` green.

(Reaching the menu headlessly also required fixing the screenshot tool's
Start-input to inject a press *edge* instead of a permanent hold.)

**Follow-up:** full SNES per-tile/sprite priority interleaving is still
approximate; this fix covers the BG3-priority menu case.

---

## 4. No music or sound effects play — FIXED

**Status:** **FIXED** (2026-07-04).

The audio engine (SPC700 + S-DSP) already produced non-silent PCM offline
(`render_song`: ~48% nonzero samples). It just wasn't wired into the live
player.

**Fix:** `play.nim` now runs the standalone APU in real time and streams
32kHz stereo PCM to a **slappy** `StreamingSource` each frame. It loads the
captured driver image and feeds the game's post-boot APU port writes live.
Key detail found by a headless probe: the game uploads the driver early
(~65KB) but streams each scene's **song data** in later, larger uploads — so
a single init plays near-silence (~0.4% nonzero). Re-initializing the APU on a
large upload jump (>=16KB = a new song) yields **~74% nonzero, sustained
audio** with only ~3 driver restarts. Deps (slappy/openal/supersnappy +
openal-soft in the flake) wired; `make test` green; live path verified to
produce sustained non-silent PCM.

**Follow-up:** the proper fix is a fully live two-way APU in the bus (no HLE
handshake, no re-init); the current MVP has a brief discontinuity on each
song change.

---

## Notes on the shared theme

The original guess that #1 and #2 shared a "per-frame budget too low" root
cause was **tested and disproven** — raising the budget changed neither the
red-static phase nor the overworld camera. #1 is animation-data selection; #2
is the demo/input path. They are separate digs, both core-emulator work.
