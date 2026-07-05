# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Filed: 2026-07-04

**Status summary (2026-07-04):**
- #1 red static — OPEN, diagnosis corrected (wrong animation *segment*).
- #2 overworld intro — OPEN, budget hypothesis disproven; input/demo path.
- #3 menu box — **PARTIAL**: border/cursor now render (BG3 priority), but the
  menu *contents* (save slots) still don't.
- #4 no audio — **PARTIAL**: offline + headless live path verified, but no
  audio heard on the `make play` menu screen yet.
- #5 game freezes on menu input — OPEN, new (blocks reaching gameplay).
- #6 EarthBound logo fade-out glitch ("B" vanishes early) — OPEN, new.

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

## 3. Menu box renders, but the menu CONTENTS (save slots) do not — PARTIAL

**Status:** **PARTIAL** (2026-07-04). Border + animating `>` cursor now render;
the interior contents (the 3 save slots) still don't.

**What's fixed — the box border/cursor.** The file-select menu is Mode 1 with
the **BG3 priority bit** ($2105 bit 3) set. The box frame + cursor live on
**BG3 high-priority tiles**; the surrounding checkerboard is opaque **BG2**.
Our compositor drew BG3 at the back, so BG2 covered it. `ppu.nim` now honors
per-tile priority: in Mode 1 with the BG3-priority bit, high-priority BG3 tiles
draw in front of BG1/BG2. The border and the animating cursor now show; `make
test` green; war-card/overworld unchanged.

**What's still wrong — the contents.** In `make play` the box frame and the
animating `>` picker appear, but most of the menu interior (the save-slot rows)
does not. Layer isolation at the menu (probe) shows why it is NOT a priority
bug: BG3-high = border + cursor only; **BG3-low, BG1, BG2 carry no slot text**.
So the slot contents simply are not in VRAM at that point — the menu appears to
be only partially initialized/populated. This likely shares a root cause with
**#5** (the menu never fully advances): if the menu logic hangs on input /
doesn't complete its setup, the slot rows never get drawn.

**Investigation leads:**
- Trace what should DMA the slot text into VRAM and whether that routine runs.
- Check the SRAM save-file read path: the slots display save data; if reading
  SRAM (empty/uninitialized) mis-branches, the rows may never populate.
- Resolve #5 first — a menu that hangs can't finish drawing its contents.

**Scope:** core-emulator PPU + menu/SRAM logic (claude-code).

---

## 4. No music or sound effects play — PARTIAL

**Status:** **PARTIAL** (2026-07-04). Offline render + a headless live-path
probe both produce sustained non-silent PCM, but **no audio has been heard on
the `make play` menu screen yet** — needs runtime confirmation of where audio
does/doesn't play interactively (title vs. menu vs. gameplay). Possible causes:
the menu's song is selected by a port command (not a >=16KB upload) so our
re-init heuristic never (re)starts it for that scene, or the interactive path
reaches the menu before/without the song data our probe saw on the attract
path. Verify by logging apuStarted / nonzero-sample counts live in play.nim.

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

## 5. Game freezes as soon as you press anything on the menu

**Status:** OPEN — new (2026-07-04), high priority (blocks reaching gameplay).

In `make play`, the file-select menu is alive (the `>` cursor animates), but
**pressing any input freezes the game**. This is the biggest blocker — nothing
past the menu is reachable until it's fixed.

Likely a core-emulator problem hit by the menu's input/selection code path
(which the idle attract path never exercises):
- An **unhandled/mis-implemented opcode or CPU edge case** the selection code
  reaches, leaving the CPU stuck or `stopped`.
- An **infinite wait loop** on something we don't service correctly (an APU
  port response, an SRAM/save read result, an IRQ/timer, an HVBJOY/RDNMI poll).
- The **SRAM save-file path**: selecting a slot reads/validates save data;
  with empty/uninitialized SRAM the routine may loop forever or branch wrong.

**Investigation leads:**
- Reproduce headlessly: boot to the menu, then inject a D-pad/A press and watch
  for `cpu.stopped`, a PC that stops advancing (tight loop), or a repeated
  read of one MMIO/SRAM address. A PC histogram / last-N-PCs trace pinpoints
  the hang.
- If it's a poll loop, identify the address it spins on and what real hardware
  would return.
- Ties to #3: the same hang likely prevents the slot contents from drawing.

**Scope:** core-emulator CPU / MMIO / SRAM (claude-code).

---

## 6. EarthBound logo fade-out glitch ("B" vanishes early)

**Status:** OPEN — new (2026-07-04).

When starting the game, the EarthBound logo fade-out looks wrong: the letter
"B" seems to vanish immediately and the transition reads as odd. Likely a
fade/color-math or per-object animation timing detail in how the logo dissolves
(the logo letters may fade via palette/color-math steps or per-tile updates we
don't reproduce at the right rate).

**Investigation leads:**
- Frame-sweep the logo fade window and watch the per-step palette/CGRAM and
  color-math ($2131/$2132) changes; compare the "B" tiles vs. the others.
- Check whether the logo uses per-letter objects/tiles that update on a
  schedule we advance incorrectly.

**Scope:** core-emulator PPU fade/animation (claude-code).

---

## Notes on the shared theme

The original guess that #1 and #2 shared a "per-frame budget too low" root
cause was **tested and disproven** — raising the budget changed neither the
red-static phase nor the overworld camera. #1 is animation-data selection; #2
is the demo/input path. They are separate digs, both core-emulator work.
