# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Filed: 2026-07-04

## 🎉 MILESTONE (2026-07-04): the game is PLAYABLE

`make play` now reaches and runs actual gameplay. Confirmed in a live session:
naming screen, start a new game, Ness's room, talk to Mom, change into day
clothes + sports cap, open the menu, equip the Cracked Bat, walk outside. The
math-unit fix (#5) was the keystone. What remains are polish gaps, below.

**Status summary (2026-07-04):**
- #1 red static — OPEN, diagnosis corrected (wrong animation *segment*).
- #2 overworld intro — **MOSTLY FIXED** by the math unit; missing the iris
  (window masking) + audio.
- #3 menu — **FIXED** (BG3 priority + math unit).
- #4 audio — **PARTIAL/BROKEN**: inconsistent across scenes; needs a live APU
  (see below — the dominant remaining issue).
- #5 freeze on input — **FIXED** (math unit).
- #6 logo "B" fade — **FIXED**: sprites now honor INIDISP brightness.
- #7 gamepad A/B swap — **FIXED** (positional mapping).
- #8 input polish — L/R **FIXED**; B/X swap, touchy diagonals, rapid-tap — open.
- #9 sprite/UI render order (per-pixel BG/OBJ priority) — OPEN, new.

## Playtest findings (2026-07-04, gameplay session)

**Audio (all #4 — the snapshot-replay APU is inadequate):** wildly
inconsistent scene to scene. name-menu Onett music plays but on a short
repeating loop; the "wow wow" name-confirm jingle doesn't play; Onett intro
music doesn't play; asteroid-crash music sometimes plays / sometimes doesn't;
police-siren music doesn't play; stepping outside the house the asteroid music
plays but with the WRONG sound effects. Talking to Mom, music kicks in but with
an "offset" — the **correct melody/sequence plays against the WRONG instrument
samples** (sounded like the intro melody with Tenda-tribe tones). Animations
always work. → This is a **coherence** failure: the SPC sequence and the BRR
sample directory / instrument table come from mismatched upload states in the
snapshot-replay image, so notes play with the wrong instruments. The real fix
is the **live two-way APU** (run the SPC700 continuously in the bus with real
$2140-$2143 I/O + the real IPL boot ROM), so sequence + samples stay coherent
exactly as on hardware. This is now the top remaining item — but it is
BOOT-CRITICAL (it replaces the HLE handshake that currently lets the game boot
into the now-working gameplay), so it must be done carefully with a fallback so
the playable boot is not regressed.

**Input (#8):** L and R now mapped (were entirely missing). Still open: B and X
feel swapped (likely a clone-controller-specific evdev mapping — need a
`--verbose` capture of what each face button reports); diagonals (up-left,
down-right) are very touchy / hard to hold; rapid d-pad taps don't all register
(likely emulated-frame cadence slower than real-time, so quick taps merge).

**Rendering (#9):** sprites and UI sometimes draw in the wrong order (a sprite
in front of UI that should be behind it, etc.). This is per-pixel BG/OBJ
priority, which our renderer only approximates. Real fix: honor per-tile BG
priority and OBJ priority-vs-BG in the compositor.

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

## 2. Overworld intro — mostly WORKS now; missing the iris transition + audio

**Status:** **MOSTLY FIXED** (2026-07-04). Characters now walk and scenes
change. Two gaps remain: the scene-transition iris and the audio.

**What fixed the motion: the hardware multiply/divide unit (see #5).** The
scene originally looked frozen (camera/characters static). The earlier
"budget too low" theory was disproven; the real blocker was the **missing math
unit** — the movement/camera/scene-script logic does multiplies and divides,
got 0 back, and stalled. With the math unit implemented, the intro now plays:
characters walk, scenes change. (Good example of one core fix cascading.)

**Remaining gap A — the "black camera shutter circle" (iris) is missing.**
Between scenes EarthBound closes a shrinking black circle (an iris/shutter)
around the action. This is **SNES window masking** — an HDMA-driven window
(WH0/WH1 per scanline traces the circle) that blanks the layers outside it to
black. We don't implement windows at all, so the iris never appears. This is
the same feature behind the "camera circle" wording in earlier notes — it's a
window mask, not a camera pan.

- Registers: W12SEL/W34SEL/WOBJSEL ($2123-$2125), WH0-WH3 ($2126-$2129),
  WBGLOG/WOBJLOG ($212A/$212B), TMW/TSW ($212E/$212F), color window (CGWSEL).
- Implement window ranges + per-layer window-disable in the compositor;
  the iris is HDMA writing WH0/WH1 each scanline.

**Remaining gap B — audio is wrong.** Same root cause as #4 (BGM / song
transitions through the snapshot-replay APU).

**Scope:** core-emulator PPU windowing (claude-code) + audio (#4).

---

## 3. Menu box + contents — FIXED

**Status:** **FIXED** (2026-07-04). Two fixes: BG3 priority (border + cursor)
and the hardware multiply/divide unit (contents). The file-select menu now
renders fully: "1: Start New Game / 2: ... / 3: ...".

The missing *contents* were not a priority bug — the menu computes its layout
with hardware multiply/divide, which was unimplemented, so it returned 0 and
never populated (and hung — see #5). Implementing the math unit made the slot
rows appear. Original border-only analysis below.

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

## 4. Audio: SFX work, but BGM (music) is silent — PARTIAL

**Status:** **PARTIAL** (2026-07-04). SFX play. Some BGM plays (the Giygas
red-static music is audible), but **song *transitions* break**: when the intro
switches to the EarthBound title fanfare it doesn't flip over — it plays a
quiet, glitchy tune instead. And the menu has no BGM at all.

**Confirmed:** a headless probe mirroring play.nim's audio path boots to the
menu and measures a steady no-input window: **0% nonzero samples** (dead
silent) vs. ~74% on the attract demo. So BGM is inconsistent across scenes.

**The song-transition glitch is the tell:** each new song is a large upload,
which trips our re-init and **resets the SPC700 mid-transition**, so the new
track comes up as garbage/quiet instead of flipping cleanly. First song fine,
the switch is not.

**Root cause — the snapshot-replay APU can't hold music state.** play.nim runs
a *standalone* APU seeded from the captured RAM image, and **re-initializes it
(resets the SPC700 to $0500) on each >=16KB upload** — 4 times by menu-time.
SFX are stateless "play this sound now" port commands, so they fire on a
freshly-reset driver. **BGM is a running sequence**: resetting the driver wipes
its music state, and replaying the captured command history does not restore it
(tested: still 0%). The re-init heuristic that made attract music ~work is
fundamentally fragile for sustained BGM across scene changes.

**Proper fix — a live two-way APU.** Run the SPC700 continuously *inside the
bus* with real port I/O (using the real SPC700 IPL boot ROM for the upload
handshake), instead of the HLE handshake + snapshot-replay. Then the driver
keeps its music state naturally and both BGM and SFX play like hardware. This
is a focused rework (risk: the HLE handshake is currently what lets the game
boot past the APU check, so the live path must handle the upload protocol).

**Scope:** audio pipeline rework (claude-code); mechanical parts (IPL ROM
bytes, port wiring) could be a grok ticket once the design is set.

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

## 5. Game freezes as soon as you press anything on the menu — FIXED

**Status:** **FIXED** (2026-07-04). Root cause: the **hardware multiply/divide
unit** ($4202-$4206 / $4214-$4217) was unimplemented — operand writes ignored,
result reads returned 0. The menu's input/selection code does multiplies and
divides; getting 0 back, it spun forever (headless probe: after input, a
~141-PC loop reading $4216 **93,052** times). Implementing the math unit
dropped that to 356 reads with 3,034 unique PCs (real progress) on both Down
and A. Fix committed with #3. Original analysis below.

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

## 6. EarthBound logo -> menu fade transition is broken

**Status:** OPEN — new (2026-07-04), detail added.

**Reference (real playthrough):** the EarthBound logo fades out ENTIRELY, then
the file-select **blue checkerboard fades IN**. A smooth cross-fade.

**Ours (`make play`):**
1. The menu does **not** fade out/in — the checkerboard just appears (no fade).
2. The logo's **"B" vanishes immediately** the instant the fade-out begins,
   while the rest of the logo is still there. Very strange / non-uniform.

So we are missing the fade transition entirely AND mis-handling the logo during
it. That the "B" alone drops instantly says the fade is NOT a uniform INIDISP
brightness ramp (that would dim all letters together) — more likely a CGRAM
palette fade (stepping palette entries toward black) or color-math, where the
"B" is a distinct palette/tile group we step or clear on the wrong schedule.
And the menu not fading in points at the same fade path not being reproduced.

**Investigation leads:**
- Frame-step the logo->menu window; dump INIDISP ($2100), CGADSUB/CGWSEL, and
  the logo palette entries each frame — is brightness ramping, or is CGRAM
  stepping toward black? Which palette does the "B" use vs the other letters?
- If it's CGRAM/color-math fade, confirm our renderer applies it per-frame at
  the sampled cadence (we may be skipping the intermediate fade frames).

Under investigation by grok (analysis-only) + a render check on the Claude side.

**Investigation leads:**
- Frame-sweep the logo fade window and watch the per-step palette/CGRAM and
  color-math ($2131/$2132) changes; compare the "B" tiles vs. the others.
- Check whether the logo uses per-letter objects/tiles that update on a
  schedule we advance incorrectly.

**Scope:** core-emulator PPU fade/animation (claude-code).

---

## 7. Gamepad A/B (and X/Y) buttons felt wrong — FIXED

**Status:** **FIXED** (2026-07-04) for standard controllers.

play.nim mapped paddy gamepad buttons by **label** (GamepadA->SNES A, etc.).
But paddy is **positional** (SDL-style): GamepadA=bottom, GamepadB=right,
GamepadX=top, GamepadY=left. The SNES face layout is X(top) Y(left) A(right)
B(bottom). By position the correct map is: paddy A(bottom)->SNES B, paddy
B(right)->SNES A, paddy X(top)->SNES X, paddy Y(left)->SNES Y — i.e. the
classic Nintendo **A/B swap** (X/Y already lined up). Fixed in play.nim.

**Caveat:** cheap SNES-clone USB pads sometimes report non-standard evdev
codes. If a specific pad is still wrong, run `make play` with `--verbose`,
press each face button, and read what paddy reports to map it exactly.

**Scope:** input mapping (play.nim).

---

## Notes on the shared theme

The original guess that #1 and #2 shared a "per-frame budget too low" root
cause was **tested and disproven** — raising the budget changed neither the
red-static phase nor the overworld camera. #1 is animation-data selection; #2
is the demo/input path. They are separate digs, both core-emulator work.
