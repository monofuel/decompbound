# Ticket: Giygas "red snow" static is the wrong animation phase

Status: OPEN (compositor fixed; animation fidelity remains)
Filed: 2026-07-04

## Symptom

The intro before the "THE WAR AGAINST GIYGAS!" title card should show **red
TV snow** — incoherent noise with red mixed in (visually the *end* of the
Giygas static, pure churning static). In `make play` we instead render a
**coherent, recognizable Giygas face pattern** that cycles colors — the
*early/structured* phase, not the snow.

monofuel (2026-07-04): "it's terrifying and haunting in a very strange way
to see this in the beginning intro. VERY COOL but we aren't quite there yet."

## What is already fixed

The color-math compositor now renders the effect at all (commit "PPU:
composited scanline renderer"). The static is BG1 (Giygas face, main) + BG2
(noise, subscreen, HDMA-scrolled per scanline via ch5 -> BG2VOFS) added via
color math (CGADSUB=03, CGWSEL=02). Before this, the screen was solid black
because the per-scanline path never did the subscreen or color math. So the
effect is now *present and cycling colors* — just not *animated as snow*.

## Root cause (hypothesis)

The snow is **motion**, not a static graphic. On hardware EarthBound rewrites
the noise source every frame — the NMI handler re-seeds BG2's scroll and/or
the HDMA table of per-scanline offsets with fresh pseudo-random values ~60x/s.
Persistence of vision turns that churn into snow. Two things compound in our
emulator:

1. **Single-frame captures can never look like snow.** A paused frame of real
   Giygas snow would also show coherent structure. So `bin/ref_giygas_static.png`
   looking coherent is expected; the test is `make play` in motion.
2. **In motion, the churn depends on timing fidelity.** The per-scanline BG2
   animation works, but the *frame-to-frame* re-randomization the game does in
   its NMI handler depends on our synthetic NMI cadence + HLE-APU timing being
   close enough. If the noise routine (likely RNG-driven) does not advance at
   the right rate, we get a slowly-drifting coherent face instead of fast snow.

So the fix is NOT in the compositor (that is correct now). It is **timing
fidelity** — making the game's per-frame noise update run at the right rate.
This is the same frame-accuracy work that will sharpen many other animations.

## Investigation leads

- Confirm the effect *is* animating in `make play` at all: does the pattern
  churn frame-to-frame, or is it frozen? (F12 two frames apart, diff the PNGs.)
- Trace what the NMI handler writes each frame during the static window
  (~frame 1000): does it rewrite the HDMA table for ch5, re-seed a scroll
  register, or touch an RNG variable in WRAM? boot_trace / a targeted watch on
  the BG2 scroll regs and the ch5 HDMA source bytes.
- Check our NMI cadence vs. real: we inject NMI once per synthetic frame at a
  fixed instruction count (screenshot: line==240; play: once per tick). If the
  game expects a specific instruction budget per frame for its RNG to advance
  correctly, mismatched cadence stalls the churn.
- Verify the HDMA indirect table is being re-read each frame (initHdma) with
  the game's updated values, not a stale first-frame snapshot.

## Scope / ownership

Core-emulator timing work — stays with claude-code per docs/delegation.md
(grok is for verification-backed grind, not subtle timing/protocol debugging).
Not a one-liner; its own focused session.

## Definition of done

- In `make play`, the intro static reads as churning red snow, not a coherent
  Giygas face, then fades to the clean title card.
- No regression: `make test` green; the title card (post-fade) and world
  frames unchanged.
