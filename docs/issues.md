# Known Issues

Current rendering / audio problems in the emulator, tracked as we chip away
at frame- and timing-accuracy. These are the things `make play` gets *almost*
right — the core boot, PPU compositor, and CPU/SPC700 cores are solid, so
these are fidelity gaps, not "it's black" bugs.

Live-play captures come from F12 (preserved `f12_NNN` bundles) per the debug workflow.

**Updated:** 2026-07-05 — restructured as a scannable status board (fixed vs. in-progress vs. open). Grouped from live-play verification this session, cross-checked against recent git log.

## FIXED (verified in live play)

- Iris/window-mask flicker (window masking + compositor).
- Sprite render order (hotel sign / street signs / Ness-behind-counter / battle sprite order / top-edge clip).
- Top-line + battle-border flicker + audio hitching (NMI-at-vblank + real-time 60 Hz pacing).
- Scene/transition delays incl. intro cards + hotel-exit + music-ahead-of-scene (InstrPerLine 40->150 CPU budget).
- Controller-disconnect crash (guarded poll+read, catches Defect).
- Alt-tab super-speed (pacing backlog clamp).
- Swirl color-math MODE (CGADSUB add/subtract bits were swapped).

## IN PROGRESS (fork/agent actively on it)

- Battle-swirl COLOR still red-instead-of-green (color-math OPERAND — fixed color / CGWSEL window). Color-math fork.
- Battle HP/PP status band cut off / black (TM=00 TS=70 subscreen band). Color-math fork.
- Boss-intro world-dim skips a bush sprite; border-less boss BG draws over UI. Color-math fork.
- gradient-test SNES test ROM fails (no gradient). Color-math fork.
- DSP SFX accuracy — "deeper" SFX wrong (Goods-menu click, swirl sound, enemy-defeated) while simple beeps are right. DSP fork.

## OPEN (not yet assigned)

- Giygas red-snow static ANIMATION fidelity (compositor fixed; animation-phase gap — see [red-snow.md](red-snow.md)).

  There is ONE Giygas death animation: swirl -> random red/black/white TV snow. The full progression is shown at the END of the game. The INTRO deliberately shows **only the snow tail** (the game hides that the snow IS Giygas until the very end — "the beginning is secretly the ending"). We render the swirl start instead. The effect now churns (animation runs) but selects the wrong segment of the death-animation data.

- Sprite-behind-object 1px flicker/lag during movement (OAM/frame-timing polish).
- test_speed ROM fails (CPU cycle-accuracy — we use a fixed instruction budget, not cycles).

Prior detailed sections for now-resolved items (old milestones, input latch, APU snapshot replay, menu hangs, logo fade, etc.) removed; still-relevant mechanics (HDMA per-line TM/TS splits for battle bands, top-scanline vblank timing, CPU budget vs. cycle accuracy) are summarized in the items above.
