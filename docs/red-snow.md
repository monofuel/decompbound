# Ticket: Giygas "red snow" static is the wrong animation phase

Status: OPEN (compositor fixed; animation fidelity remains)
Filed: 2026-07-04

## Symptom

There is ONE Giygas death animation that runs **Giygas swirl -> random
red/black/white TV snow**. The full progression is shown at the END of the
game. The INTRO deliberately shows **only the snow segment** (the tail of that
animation) and never the swirl — because the game is hiding that the snow IS
Giygas until the very end. "The beginning is secretly the ending" is the
central trick.

Our bug: in the intro `make play` renders the **swirl (start) segment**
instead of the **snow (tail) segment**. We are showing the wrong slice of the
animation — and spoiling the reveal.

monofuel (2026-07-04): "for the actual animation at the end of the game, it
does progress through the animation from 'clearly giygas' to 'random snow'.
but the intro animation ONLY shows the random snow, the final part of the
animation, it does NOT show the initial giygas part. the game intentionally
keeps giygas a secret from us until the very end... clever end of game is the
beginning bit."

### Evidence (2026-07-04 frame sweep, screenshot tool, noinput)

Rendered the static window at frames 1300 / 1500 / 1700 / 1850 / 1920 (color
math CGADSUB=03, CGWSEL=02, subscreen TS=02 the whole time), then 1960 where
CGADSUB flips to 00 and the clean UFO-town card shows.

- The pattern **does churn** frame-to-frame (1500 vs 1700 differ) — so the
  per-frame animation is running; this is NOT a frozen-render bug.
- But it shows the **coherent Giygas swirl the entire window** (1300 -> 1920),
  i.e. the START of the animation, when the intro should show the SNOW tail.
- Budget is NOT the cause: raising instructions-per-frame ~6x (IPL sweep) did
  not change what is shown.

Conclusion: the churn/animation runs fine; the **wrong frames/tiles are
selected** for the intro. The intro's setup should seek to (or stream) the
snow-tail frames of the death animation; we are sourcing the swirl-start
frames instead.

## What is already fixed

The color-math compositor now renders the effect at all (commit "PPU:
composited scanline renderer"). The static is BG1 (Giygas face, main) + BG2
(noise, subscreen, HDMA-scrolled per scanline via ch5 -> BG2VOFS) added via
color math (CGADSUB=03, CGWSEL=02). Before this, the screen was solid black
because the per-scanline path never did the subscreen or color math. So the
effect is now *present and cycling colors* — just not *animated as snow*.

## Root cause (hypothesis)

This is an **animation-frame-selection** problem, not a compositor or raw
timing problem. The intro must display the *snow tail* of the death
animation. Our render shows the *swirl start*. So whatever chooses which slice
of the animation the intro plays is landing on the wrong slice in our
emulator.

The death animation frames are (almost certainly) a stream of tile/graphics
data that the game decompresses/DMAs into VRAM (BG1 face + BG2 noise layer)
frame by frame, indexed by an animation counter/pointer. The intro sets that
counter/pointer to the snow portion; end-game plays from the swirl start. We
render the swirl, so either:

1. The intro's animation index/pointer is initialized to the start instead of
   the snow offset (setup code seeking to the snow frames didn't run, or wrote
   the wrong value), OR
2. The per-frame tile stream is sourcing from the swirl-frame data (wrong
   source address / decompression offset), OR
3. The intro and end-game share a routine and a mode flag selects the segment;
   we mishandle that flag so the intro behaves like end-game-from-start.

The churn we DO see means the animation engine advances; it is just reading
the wrong part of the animation data.

## Investigation leads

- Diff the intro against the end-game death animation: if the intro's frames
  match the *first* frames of the end-game sequence, confirms "wrong segment /
  index reset to 0" rather than "wrong data entirely."
- Trace the animation setup right before the static window (~frame 1300):
  what WRAM variable(s) hold the animation frame index/pointer, and what does
  the intro write to them vs. the end-game path?
- Find where the death-animation tile data streams from in ROM and which
  offset the intro uses; verify our DMA/decompression sources the snow frames,
  not the swirl frames.
- Check for an intro-vs-endgame mode flag the animation routine branches on.

## Scope / ownership

Core-emulator timing work — stays with claude-code per docs/delegation.md
(grok is for verification-backed grind, not subtle timing/protocol debugging).
Not a one-liner; its own focused session.

## Definition of done

- In `make play`, the intro static reads as churning red snow, not a coherent
  Giygas face, then fades to the clean title card.
- No regression: `make test` green; the title card (post-fade) and world
  frames unchanged.
