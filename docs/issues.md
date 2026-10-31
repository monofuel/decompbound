# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Live-play captures come from F12 (preserved `f12_NNN` bundles) per the debug workflow.

**Human eyeballs:** short "run this / pass if" checks live in
[`docs/human-verify.md`](human-verify.md) — not buried in chat. This file is the
durable status board (FIXED / IN PROGRESS / OPEN); human-verify is the active
checklist monofuel ticks while playing.

**Known-good play baseline + the 2026-07-08 audio/visual incident** (room-entry
hang, Saturn Valley corruption, half-speed music) are tracked together in
[`docs/play-regressions.md`](play-regressions.md), including the fallback commit
`0bdad72` and the salvage path for the orphaned fixes.

**Updated:** 2026-07-05 — restructured as a scannable status board (fixed vs. in-progress vs. open). Grouped from live-play verification this session, cross-checked against recent git log.

## Known viewport extension bugs

The current polish target is **336×256**, preserving the original 256×224
image in the center. Larger presets such as 512×384 remain experimental.
This is an inventory of bugs and limitations, **not a commitment to fix every
entry**. A difficult issue can remain an accepted limitation. Scene-specific
presentation fixes or original framing with black borders are valid outcomes;
the named per-scene rule list is proposed, not implemented yet.

For new reports, record the scene or private screenstate filename, viewport
size, observed behavior and chosen disposition. Keep uncertain causes labeled
as hypotheses. Prefer presentation-only fixes; changes to gameplay activation
or simulation need separate justification.

| Issue / gap | Evidence | Disposition |
|---|---|---|
| Photoman shutter exposes extended scenery | Monofuel reports that scenery in the extended margins remains visible outside the shutter effect when Photoman takes a photo. The animation's exact start/end conditions have not been traced. | **Deferred; record only for now.** Temporarily using original framing with black borders during the shutter animation is a possible workaround, not an implemented fix. |
| Winters daytime / falling-leaves border flash | Monofuel reports that the black border briefly appears for about one frame when Winters becomes daytime and the leaves start falling. The flash is distracting; no frame-level reproduction or fallback reason has been captured yet. | **Deferred; record only for now.** Correlate the transition with the selected presentation/fallback reason before changing clipping or effect support. |
| Trees exposed behind Threed tunnels | Monofuel reports trees visible beyond/behind the tunnels in the extended margins, where normal framing conceals them. Other towns may have the same issue, but that has not been confirmed. | **Deferred; record only for now.** A presentation-only continuation of tunnel tiles/walls or a verified mask could conceal the extra scenery. No tunnel hack is implemented. |
| Ghost tunnel pushback snaps to black borders | Monofuel confirms the tunnel ghosts animate correctly while speaking, but the pushback to Threed abruptly switches to original framing with black borders. The specific fallback condition has not been traced. | **Deferred, low priority; record only for now.** Extending the pushback cutscene would be desirable, but the current fallback is acceptable pending investigation. |
| Thin background-coloured line through edge sprites | Human-reported intermittent seam. Silent replay of the current private session reproduces a one-pixel gap at the original top edge; details below. | **Open, reproduced.** Validate native edge clipping and unused OAM handling before choosing a repair; no rendering fix is implemented. |
| Rare pop-in at the 336×256 target | Monofuel reports intermittent pop-in involving an enemy on the left edge and the “do not enter” sign near the Threed graveyard. It usually works and is not yet reliably reproduced. | **Open.** Keep separate from the accepted larger-preset loading limit; clipping, resources and native loading remain possible causes. |
| Battle backgrounds do not extend left/right in many fights | Missing mode-1 four-bit BG2 support explained the reproduced `earthbound_20261031-154410_2.png` failure. Both the common four-bit path and the existing two-bit path now extend horizontally; normal top/bottom framing stays intact. Evidence below. | **Fix ready for manual retry.** Rebuilt core passes side-pixel, animation, native-center, PCM and complete machine-state checks. Keep any remaining exceptions open rather than assuming every fight is verified. |
| Added battle top/bottom rows flicker black | Monofuel reports flickering borders in `earthbound_20261031-154410_2.png` and `earthbound_20260817-011526.png`. Silent replay reproduced intermittent vertical model rejection while horizontal extension remained active. | **Fix ready for manual retry.** Match animation phase against captured working WRAM scroll as well as displayed VOFS; require agreement with all native rows before extending. Details below. |
| Skyrunner sky/cloud cutscene exposes blue fill | Monofuel reports unwanted blue background along the bottom and right of the extended cloud scene. The existing native-area comparisons do not verify intended framing in the added margins. | **Open, bounded workaround acceptable.** Either keep original framing for this scene or derive a scene-specific cloud/mask fix. Neither rule is implemented yet. |
| Battle swirl retains a black border | Monofuel observes that the battle-entry swirl uses original framing and considers that acceptable. | **Accepted limitation.** Extending the swirl is optional and low priority. |
| Sanctuary boss backgrounds repeat horizontally | In private `earthbound_20260818-005528.png`, Monofuel reports that the sanctuary boss background fits vertically but loops across the extended horizontal area. The repeated pattern looks odd. | **Deferred; record only.** A scene-specific composition adjustment may be desirable, but this is not a critical issue and no change is requested yet. |
| Flash-back shutter conflicts with extended framing | In private `earthbound_20260728-045735.png`, Monofuel reports that the cropped borders look at odds with the shutter's circular border. | **Deferred; record only.** The circular effect and viewport framing need a coordinated policy; no rendering adjustment is requested yet. |
| PSI effects retain viewport quirks | Monofuel reports quirks with some PSI effects, including PSI Starstorm in private `earthbound_20260725-190159.png`. Exact effect bounds and masking have not been diagnosed. | **Deferred; expected, acceptable for now.** Polishing these effects for the extended viewport is optional future work, not part of the battle-border repair. |
| Runaway Five dimming and concert framing | In private `earthbound_20260710-211636.png`, Monofuel reports incorrect light dimming before the performance and a snap back to black borders during the concert. He expects the concert to retain the extended viewport. | **Deferred; record only.** Lighting composition and the concert's fallback condition need diagnosis; no fix is implemented. |
| Tea-scene text filter appears square | In private `earthbound_20260708-225439.png`, Monofuel reports broken extended framing with a square-looking filter around the text. | **Open, uninvestigated.** Trace the scene's native text/effect mask before choosing extended composition or an intentional framing rule. |
| Initial title cards retain original framing | Monofuel reports that the initial title cards do not use the extended viewport. | **Deferred, low priority.** Wider title-card composition would be desirable future polish. |
| Sound Stone screen polish | In private `earthbound_20260707-015742.png`, Monofuel considers the current extended presentation a little quirky but fine as it is. | **Accepted for now; optional future polish.** No repair is requested. |
| Scaraba sailing switches to bordered framing | Private `earthbound_20261031-165947.png` repeatedly crosses camera X=0. The published word for X=-19 was read as 65517 and rejected as outside the atlas; crossing zero briefly re-enabled expansion. | **Fix ready for manual retry.** Decode signed camera words, preserve arrangement-zero fill outside the atlas, and retain native publication checks. Evidence below. |
| NPC pop-in at larger viewport sizes | On 2026-10-31, Monofuel confirms the NPC extension works at 336×256, but reports NPCs appearing near that visible range when using 512×384. The renderer has no 336×256 cutoff. Native actor loading is a suspected cause; the exact activation boundary has not been traced. | **Accepted limitation for the current milestone.** Polish 336×256 first; increasing native loading/activation ranges is not part of the current fix. |
| Special scripted actor effects are not extended | Implementation limitation: ordinary active `$A3A4` bodies are extended, while `$AC43` effects and unusual draw callbacks remain native. This is not an established cause of the individual scene reports above. | **Deferred.** Investigate individual scenes when useful; a presentation workaround or original framing may be sufficient. |
| Exact room isolation at larger sizes is unverified | Map-family clipping is implemented, but a logical family can contain several disconnected rooms. Specific unwanted neighboring-room exposures still need a scene report; this is a coverage gap, not a confirmed room-specific bug. | **Deferred unless encountered.** Avoid a broad room-boundary rewrite without a concrete case. |

Monofuel confirms that the autoplay intro scenes already look fine: their
native circular framing conceals the extended area, so no visible change is
expected there. Preserve that framing; this is separate from the reported
flash-back shutter problem.

### Scaraba sailing at the atlas edge

The camera's signed X oscillates around zero in
`earthbound_20261031-165947.png`. Before the repair, a silent replay stayed
`padded camera-oob` until frame 200, extended at X=0, then returned to padding
at frame 207 when X=-1 was interpreted as 65535. The map layout, mode, scroll
lanes and native publication otherwise remained valid, without HDMA.

The original map readers sign-extend negative input coordinates at
`$C00AD8..$C00AE4` and `$C00BEB..$C00BF6`; their out-of-range paths
`$C00B9D/$C00CAD` select arrangement zero. The viewport now uses signed camera
coordinates and allows an original frame overlapping the atlas edge, while
still checking every visible tilemap word. Negative X uses bit 8 for the native
horizontal ring bank; truncating division incorrectly selected the other bank.
Sprite publications compare equivalent 16-bit camera words.

Silent checks pass 480 uninterrupted frames at each of the five presets:
scenery matches the independent PPU oracle, original pixels/PCM/complete
CPU/machine state match, and no frame falls back to a black border. Boundary
fixtures retain rejection at X=-256/Y=-224 and for ambiguous scroll lanes.
The full scene archive reports 779 maps, 306 battles, 206 padded states, seven
image-only captures and zero background mismatches. A 900-frame diagnostic
also stays extended and has been retired into these tests and docs.

```sh
nim r --opt:speed tests/integration_expanded_viewport.nim --sailing \
  "$HOME/Pictures/Screenshots/earthbound_20261031-165947.png"
```

### Reproduced sprite seam evidence

At 336×256, the original image starts at output `(40,16)`. Replaying private
`bin/libretro/earthbound-viewport-saves/captures/session-IKqDCGIn/segment_0001.json`
reproduces 13 missing actor pixels at original Y=0 (output Y=16), X=146..158,
on zero-based replay frame 501. Further cases occur on frames 513, 569, 581
and 593. A native OAM element at X=144, Y=240 has size 16: the existing
`ppu.renderSprites` parked-sprite heuristic skips `Y + size <= 256`, omitting
its wrapped final row. The unwrapped viewport raster includes that row, then
the original-image blit replaces it with the native background. This is a
concrete top-edge case; other reported edge artifacts may have separate causes.

Reproduce silently with the retained diagnostic:

```sh
nim r src/probes/probe_viewport_sprite_seam.nim \
  bin/libretro/earthbound-viewport-saves/captures/session-IKqDCGIn
```

The probe uses the private checkpoint and recorded inputs, stops after five
mismatching frames, and writes an image-only preview to ignored
`bin/viewport-seam-first.png`. It opens no windows or audio devices and leaves
the source session untouched. No checkpoint or image is committed. Changing
the general parked-sprite heuristic needs care: unused OAM slots also use
offscreen Y values, so removing the guard without validation could reintroduce
top-row garbage. Keep the report open until a repair is verified visually.

### Reproduced battle extension coverage gap

Monofuel's private `earthbound_20261031-154410_2.png` shows the battle results
dialogue over a textured background, with black side margins at 336×256.
A silent three-frame replay observed `$2105=$09` (mode 1, BG3 priority) on all
224 visible rows. The previous viewport gate accepted only mode 0 and rejected
this frame at row zero. The map fallback also rejected its HDMA configuration.

The test archive selector also excluded mode-1 captures. It now includes the
native four-bit allocation, and explicit replay checks require visible pixels
on each added side, in addition to unchanged original pixels, PCM and complete
CPU/machine state. Native top/bottom letterboxing remains a separate contract
from vertical continuation.

The implementation recognizes the original BG2 map/CHR allocation and playable
battler pointer, rather than treating every mode-1 scene as a battle. It routes
the first background driver and `$3C46` wave to BG2; BG3 UI stays centered.
Window ranges covering the complete native width expand with the output, while
narrower effect windows retain their translated bounds. Referenced background
tiles/maps must remain stable; unrelated UI/OBJ uploads do not invalidate them.
Native format evidence is in [battle-backgrounds.md](battle-backgrounds.md#composition-coverage-and-open-research).

Reproduce both paths and their pixel/state checks without a window or audio device:

```sh
nim r --opt:speed tests/integration_battle_viewport.nim \
  "$HOME/Pictures/Screenshots/earthbound_20261031-154410_2.png" \
  "$HOME/Pictures/Screenshots/earthbound_20260706-213532.png"
```

The diagnostic probes have been retired into the renderer and regression tests.
The failing capture has visible pixels in both 40-pixel side strips after
restore, including 6,400 coloured pixels per side in the sampled 160-row body
region at replay frames 2 and 15. This repair awaits manual acceptance.

The follow-up top/bottom flicker is a different failure: continuation fitting
seeded horizontal-wave phase from displayed VOFS. Original `$C0AEA8..$C0AEB1`
instead reads working vertical scroll at `$0033 + (backgroundId - 1) * 4` and
adds the angle before generating the wave. For BG2 this is `$0037`, already
captured by the viewport. Working scroll can lead or lag displayed VOFS:
in the first capture at replay frame 3, angle 238 and working Y=90 generate
the observed phase, while the displayed Y is still 88. Using displayed Y
alone intermittently rejected the current frame and left the added rows black.

Fitting now tries the captured working scroll, retaining displayed-scroll
matching for queued states, and still verifies every visible row. It does not
reuse the previous frame's model. A synthetic regression varies the two scroll
values independently through phase/scroll wrapping; explicit replay option
`--continuous-vertical` checks 360 frames at every preset and fails when either
added vertical band goes black after the initial restore frame.
Both reported captures pass that check at all five presets, including unchanged
native pixels, PCM and complete CPU/machine state. The 10 battle unit tests and
the 373-capture battle archive also pass; 306 archive captures extend and the
remaining cases retain their existing fallback. Manual confirmation is pending.

```sh
nim r --opt:speed tests/integration_battle_viewport.nim --continuous-vertical \
  "$HOME/Pictures/Screenshots/earthbound_20261031-154410_2.png" \
  "$HOME/Pictures/Screenshots/earthbound_20260817-011526.png"
```

HDMA/mosaic and other unsupported configurations already use deliberate black
padding; extending every effect is optional. Desktop tearing is tracked under
[OPEN](#open-not-yet-assigned), since it concerns frontend presentation rather
than the extra scene content. Implementation contracts and verification remain
in [expanded-viewport.md](expanded-viewport.md); manual checks remain in
[human-verify.md](human-verify.md#expanded-viewport-desktop-prototype).

## FIXED (verified in live play)

- Iris/window-mask flicker (window masking + compositor).
- Sprite render order (hotel sign / street signs / Ness-behind-counter / battle sprite order / top-edge clip).
- Top-line + battle-border flicker + audio hitching (NMI-at-vblank + real-time 60 Hz pacing).
- Scene/transition delays incl. intro cards + hotel-exit + music-ahead-of-scene (InstrPerLine 40->150 CPU budget).
- Controller-disconnect exception in `play.nim` (guarded poll+read, catches Defect).
  This was an app guard, not a dependency fix; see the jukebox hotplug item below.
- Alt-tab super-speed (pacing backlog clamp).
- Swirl color-math MODE (CGADSUB add/subtract bits were swapped).
- Giygas intro red-snow (Mode 7 multiply for HDMA distortion; 2026-07-08 — please confirm in `make play`).
- INIDISP brightness 0 = true black (was `(n+1)/16`, never reached black — Halken/battle
  fade linger on last dim frame).
- Logo glow 1px bottom gap (2026-07-08): OAM sprites were drawn at Y instead of Y+1.
  Hardware places sprites one scanline below OAM Y; hard letter faces sat 1px above the
  BG soft-glow fringe. Fix: `screenY = y + py + 1` in `renderSprites` (linear, no wrap).
- Top scanline garbage after logo fix (2026-07-08): `(y+py+1) and 0xFF` wrapped the
  last row of **Y=$E0 size-32 “offscreen”** sprites onto line 0 (battle UI / overworld).
  Real range is linear 225..256 (outside 0..223). Dropped 8-bit wrap; line 0 clean.
- Battle BG over UI / borderless battles (2026-07-08 live confirm: Mini Barf fight
  shows full psychedelic BG + HP/PP windows + dialogue). Mode-0 per-tile priority
  ladder (`bg3prio` is mode-1-only; commits `01e8084` / `cc898f6` / `eb3f714` /
  `194d450`). Was drawing animated BG in front of command/status UI.
- Battle BG “over” UI via color math (2026-07-08): CGADSUB half-math on BG3 was
  applied to *every* main pixel, so BG1 UI was half-blended too and the animated
  BG looked painted on top. Fix: track topmost layer per pixel; only math when
  that layer’s CGADSUB bit is set (hardware).
## IN PROGRESS (fork/agent actively on it)

- Battle-swirl COLOR still red-instead-of-green (color-math OPERAND — fixed color / CGWSEL window). Color-math fork.
- Battle HP/PP status band cut off / black (TM=00 TS=70 subscreen band). Color-math fork.
- Boss-intro world-dim skips a bush sprite. Color-math / priority fork.
- gradient-test SNES test ROM fails (no gradient). Color-math fork.
- DSP SFX accuracy — "deeper" SFX wrong (Goods-menu click, swirl sound, enemy-defeated) while simple beeps are right. DSP fork.

## OPEN (not yet assigned)

- **Expanded viewport / desktop presentation tearing.** Monofuel confirms the
  outdoor prototype works but reports a "vsync vertical tear". Its orientation,
  position and behavior at the original viewport size are not yet isolated.
  The previous desktop path used unsynchronized Windy `XPutImage` uploads;
  changing its vsync boolean alone could not synchronize those uploads.
  **Fix ready for manual verification:** mono-retro now defaults to native-size
  X11 GPU textures, nearest scaling and double-buffered GLX swaps with interval
  one. Windy's opt-in GPU pixel context works alongside `useCpu` builds. Explicit
  `--video:cpu` retains the comparison path. Private Xvfb tests passed actual
  colour/crop readback, resize, two windows, input, state drops and paced real-core
  playback, including the 336x256 outdoor viewport. Xvfb tests use null audio and
  disable vsync; they cannot prove physical tear-free behavior. The earlier Anbernic fix
  used DRM double buffering/vblank page flips and paired GPU atomic presentation,
  which are separate from X11. Reproduction and acceptance live in
  [human-verify.md](human-verify.md), Expanded viewport desktop prototype.

- **RG DS Plus residual native audio underrun (2026-10-29).** Repeated
  300-frame cave tests reported one underrun with both the previous `380b41b`
  core and optimized `ab07a7a`; later paired runs reported zero for both.
  Battle improves from 28–29 previous to 0–1 optimized. Core PCM hashes match
  exactly across ordinary/batched execution and ARM/x86. The remaining
  intermittent counter increment's timing/cause and audible impact are not
  isolated; investigate player/device pacing without weakening emulation gates.
  On 2026-10-30 Monofuel reports that gameplay is good but thinks slight audio
  crunch remains. No concurrent timing/counter evidence establishes whether
  that sound coincides with these underruns; audio acceptance remains open.
  Reported reproduction: load the configured savestate, open inventory, use
  the Bad Key Machine on the door. GC, changing clocks, bursts of emulation
  work and frontend scheduling remain uncorrelated hypotheses.
  After the combined palette-core/GPU-player update, Monofuel reports overall
  gameplay is flawless. A separate retest of this exact item-use sequence and
  its counter correlation is not supplied; this issue now concerns that narrow
  remaining reproduction rather than general play performance.
  Evidence and rollout details: [libretro-performance.md](libretro-performance.md#shipping-rollout-and-native-audio-observations).

- **Pocket Atlas / Deep Darkness assets show through darkness
  (2026-10-29).** Human-reported visibility discrepancy: scenery assets appear
  through the shroud where they are expected to stay hidden in normal play.
  The default cleared-story-flags variant explains the palette selection;
  palette selection alone does not settle whether this visibility is correct.
  Root cause remains under investigation. Reproduction and visual verification:
  [human-verify.md](human-verify.md), Found in play.
  Direct reproduction: `make map-app ARGS="--x:4842 --y:7566 --zoom:2 --flag:0120=off"`.
  Original-code investigation now reproduces the same patches in our emulator
  after relocating an actual pre-Hawk-Eye state into the affected area. Native
  scenery matches all 57,344 background pixels produced by our own PPU; OAM
  does not hide the patches. This is not an independent console reference.
  monofuel expects these objects to remain hidden during normal console play.
  Further original-code evidence proves a transparent collision gate at
  `(6016,7960)`: it spawns with `$0120` clear and blocks movement; removing
  only that object permits movement without changing the palette flag. Thus
  the warped comparison exposes normally restricted map data and does not
  establish a PPU defect. The complete reachable-camera boundary and a console
  comparison remain unverified. See
  [world-map.md](world-map.md#deep-darkness-investigation). Keep this issue open;
  do not substitute a guessed atlas mask for missing evidence.

- **Pocket Jukebox controller disconnect — fix ready for physical retry
  (2026-10-27).** monofuel reported a crash after unplugging; the terminal trace
  was lost. The old Paddy pin retained a udev-owned path after unref and mishandled
  HUP/ENODEV removal. The lock now uses monofuel's `5bc2573`, which owns the path
  and handles those removal paths. `make jukebox-gamepad-test` uses a real uinput
  controller, bounded child polling, removal and reconnection; it passes. This
  fixes the known dependency defects without swallowing arbitrary exceptions.
  Confirm the original hardware through [human-verify.md](human-verify.md).

- **Saturn Valley hot-spring VRAM corruption needs a queue-level diagnosis.**
  The `pi3-perf` experiment skipped large or translated VRAM DMA requests.
  Transfer size alone cannot distinguish a damaged CHR job from valid hardware
  behavior, so `master` executes those transfers. `tests/test_vram_dma.nim`
  covers synthetic 48 KiB linear and 24 KiB translated uploads. Preserve the
  original queue evidence on `pi3-perf` when investigating the producer.

- ~~Giygas red-snow static ANIMATION fidelity~~ **FIXED 2026-07-08** (see [red-snow.md](red-snow.md)).
  Missing Mode 7 multiply (`$211B`/`$211C` → `$2134`–`$2136`) left the HDMA
  BG2HOFS distortion table all zeros, so the intro showed a coherent Giygas
  face tile grid instead of warped TV snow.

- ~~**Door exit → black exterior (force blank stuck)**~~ **FIXED 2026-07-08**:
  save-state v1 restored SPC RAM/PC/ports but **not APU timers** (`$F1`/`$FA`–`$FC`).
  After `--load-state` (llm-ai bedroom fixture) timer 0 stayed disabled; music
  driver spun at APU `$0579` (`MOV A,$FD` / `BEQ`) and never acked `$2140`, so
  the main CPU stayed in `$C0ABD0` wait and left `INIDISP=$80`. `make play` from
  cold boot was fine (driver init enables T0). Fix: state v2 serializes timers;
  v1 loads call `recoverTimersAfterLoad` (enable T0, target from APU `$53` or
  `$10`). Probes: `probe_door_apu.nim`, `probe_outside_black.nim`.

- Sprite-behind-object 1px flicker/lag during movement (OAM/frame-timing polish).
- test_speed ROM fails (CPU cycle-accuracy — we use a fixed instruction budget, not cycles).

- **2nd sanctuary (Lilliput Steps cave mouth) — 1-tile black column**
  (2026-08-18, reproduced on **two** independent playthroughs).
  ~8px **viewport-fixed** vertical hole through the overworld at the
  cave: grass/rock/path missing, sprites still draw. Not a world tile
  (column stays on screen when the camera moves). **No HDMA**
  (`HDMAEN=00`), no color math (`CGADSUB=00` `CGWSEL=00`), `BGMODE=09`
  `TM=17` `BG1SC=39`. BG1/BG2 scroll locked together.

  | Run | F12 (local `~/Pictures/Screenshots/`, do not commit) | pos | bg1 scroll |
  |-----|------------------------------------------------------|-----|------------|
  | 2026-08-18 TAS | `earthbound_20260818-005541.png` `005543` `005556` | `(0C20,1FDB)` | (928, 875) |
  | 2026-07-07 | `earthbound_20260707-014807.png` `014825` `014835` | `(0C18,1FDA)` → `(0C05,1FEF)` | (920,874) → (901,895) |

  Probe: `nim r src/probes/probe_sanc2_column.nim`. Reload any F12 via
  drag-drop / `make play-cont` from that PNG. Hypothesis: mode-1 BG
  tilemap fetch / 64-wide wrap at this HOFs, not a map-data hole.

Prior detailed sections for now-resolved items (old milestones, input latch, APU snapshot replay, menu hangs, logo fade, etc.) removed; still-relevant mechanics (HDMA per-line TM/TS splits for battle bands, top-scanline vblank timing, CPU budget vs. cycle accuracy) are summarized in the items above.

## Known-failing e2e tests (2026-09-19)

The Pi investigation recorded eight `tests/e2e_*.nim` failures in the
LLM-play bot harness: `e2e_agent_giant_day_gs80`,
`e2e_agent_knock_bed`, `e2e_agent_multileg`, `e2e_agent_product_gs70_to_gs80`,
`e2e_campaign_full_product_spine`, `e2e_campaign_segment`, `e2e_late_game_spine`,
`e2e_stuck_recovery`. Its recorded comparison found identical failures at
`ec60278` and after the Pi optimization series. These bot milestone failures
remain open; the current integration's unit, ROM-integration, capture, and
replay-golden checks do not establish that the full bot e2e suite passes.

## Perf / investigations

- **Rare `make play` frame stutter (INVESTIGATING 2026-07-19).** A very rare,
  transient hitch during play (observed mid-dialogue, "What brings you to the
  Monotoli Building?") that **does not** correlate with autosnaps or any game
  event. **Hypothesis (monofuel):** Nim GC pause — we're on the default
  `--mm:orc` (Nim 2.2.4), whose **cycle collector** fires periodically → a rare,
  game-uncorrelated pause. Fits the symptom.
  - **Test in progress:** temporary `config.nims` sets `--mm:arc` (deterministic
    RC, no cycle collector = no GC pauses). Play a session; hitch gone ⇒ confirmed.
    ARC leaks true cycles → diagnostic build only; revert by deleting `config.nims`.
  - **Real fix (if confirmed):** kill hot-path garbage — `ppu.modeLayers` allocates
    a `seq` **per scanline (~262×/frame)**; `overlayForegroundBg` builds a `passes`
    seq/frame; per-frame `&"…"` title/log strings. Preallocate/reuse; optionally
    `GC_fullCollect()` at an idle point (vblank/pause) so it never lands mid-frame.
  - **2026-09-19:** the PPU garbage is gone (`modeLayers` iterates const tables,
    `overlayForegroundBg` uses a fixed array, `runHdma`/`runDma` index a const
    pattern table, the per-frame audio buffer is allocated once). Title strings
    remain (off under `--kiosk`). Whether the hitch is gone is unverified.
  - Instrumentation ideas if not the GC: slow-frame detector (log frame + `seg`
    replay anchor when wall-time > budget), surface per-frame `apuPortCatchup`,
    per-phase timing breakdown.

- **ROOT CAUSE FOUND + FIXED (2026-07-20): `bus.dirty` unbounded growth.**
  `cpu.write8` appended every touched address to `bus.dirty` on *every* memory
  write. That list is consumed ONLY by the vector-test harness (`run_vectors`), so
  in normal emulation it grew one `int` per write **forever** — the per-frame
  Nim-heap leak AND the rare frame stutter (its capacity-doubling `seq` periodically
  realloc-copied millions of ints mid-frame). **Fix:** gate the append behind
  `Bus.recordDirty` (default OFF); the vector harness + single-step test opt in.
  Headless proof: core leak **3563 B/frame heap + 6901 B/frame RSS → 0 on both**
  (`probe_frame_leak`, every subsystem mode). Regression test: `tests/test_frame_leak.nim`.
  - How it was found (all headless, no windows): (1) realized live=RssAnon vs
    probe=getOccupiedMem measure different pools; (2) `probe_audio_leak` (OpenAL
    direct) → audio CLEAN; (3) `probe_gl_leak` (surfaceless EGL, real driver, no
    window) → `glTexImage2D`-per-frame FLAT (GL theory wrong); (4) subsystem
    bisection in `probe_frame_leak` → identical 3563 B/frame in EVERY mode incl.
    `emuonly`, pointing at cpu.step/bus; (5) grep → `bus.dirty.add` in write8.
  - The scene-dependence explains why live (busy Fourside, more CPU writes/frame)
    leaked ~80 MB/min while the quiet `game_start` probe state showed less: the
    leak scales with writes-per-frame.

- **~~Live `make play` memory leak~~ (superseded by the dirty-seq root cause above).**
  Historical notes: live RssAnon climbed
  ~80 MB/min (was ~135 before the trace-seq fix). Key realization: the live number
  is **RssAnon** (`/proc`), but the headless probe measured **getOccupiedMem()**
  (Nim GC heap only) — different pools. RssAnon also holds OpenAL PCM buffers and
  the GL driver's texture storage, which a Nim-heap probe is structurally blind to.
  Isolation probes now report **both** metrics. Results:

  | Path (isolated) | Nim-heap | RssAnon | verdict |
  |---|---|---|---|
  | `probe_audio_leak` paced+pump (OpenAL only) | 0 B/frame | **0.3 MB/min** | audio CLEAN — `pump()` keeps up |
  | `probe_audio_leak` nopump control | 5 B/frame | 8.1 MB/min | proves the probe *can* see OpenAL leaks |
  | `probe_frame_leak` core (emulate+render+audio-tick, no GL/OpenAL) | 3563 B/frame | 6901 B/frame (~24 MB/min flat-out) | residual core leak — still unpinned |
  | live `make play` (all paths) | — | ~80 MB/min | GL upload ≈ the remaining ~56 MB/min |

  - **OpenAL exonerated.** With real-time pacing + `pump()`, the audio queue is flat.
  - **Prime suspect: the per-frame `glTexImage2D`** (play.nim ~L971) *reallocates*
    a 256×224×4 = 229 KB texture every frame. On a Mesa/software GL driver that
    realloc churn accumulates in RssAnon. **Likely fix:** one-time `glTexImage2D` to
    allocate, then `glTexSubImage2D` each frame to reuse the same storage.
  - **Confirm live:** `./bin/play --no-tex <rom>` (skips the upload) vs `--no-audio`
    vs normal — watch the mem heartbeat. Whichever flattens RssAnon is the culprit.
  - **Residual core leak** (~3.5 KB/frame Nim-heap) persists after the trace-seq fix
    — the hot-path `seq` churn (`ppu.modeLayers` per scanline, `overlayForegroundBg`
    passes/frame) is the likely source; same target as the stutter fix above.
