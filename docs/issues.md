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

**Updated:** 2026-07-05 — restructured as a scannable status board (fixed vs. in-progress vs. open). Grouped from live-play verification this session, cross-checked against recent git log.

## FIXED (verified in live play)

- Iris/window-mask flicker (window masking + compositor).
- Sprite render order (hotel sign / street signs / Ness-behind-counter / battle sprite order / top-edge clip).
- Top-line + battle-border flicker + audio hitching (NMI-at-vblank + real-time 60 Hz pacing).
- Scene/transition delays incl. intro cards + hotel-exit + music-ahead-of-scene (InstrPerLine 40->150 CPU budget).
- Controller-disconnect crash (guarded poll+read, catches Defect).
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

Prior detailed sections for now-resolved items (old milestones, input latch, APU snapshot replay, menu hangs, logo fade, etc.) removed; still-relevant mechanics (HDMA per-line TM/TS splits for battle bands, top-scanline vblank timing, CPU budget vs. cycle accuracy) are summarized in the items above.
