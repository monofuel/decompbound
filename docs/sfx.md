# Sound & SFX — the S-DSP accuracy track

**Status:** music is recognizable, **specific SFX still wrong.** Iterative — this is a
long tail of DSP-synthesis fidelity.

The goal: **every SFX, PSI sound, and music instrument sounds *right*** — a faithful
S-DSP so the audio matches hardware, not just "plays something." Distinct from
`docs/music.md` (getting songs to *trigger*) — this is about the *synthesis* of the
samples once they play.

## Where it stands

The S-DSP (`src/decompbound/dsp.nim`) has landed, in order: echo/FIR, 4-tap Gaussian
interpolation, ADSR + GAIN envelopes, the BRR 15→16-bit volume recovery, **PMOD (pitch
modulation)**, and a PMOD high-pitch-sweep crop. Music is recognizable; the volume is
right; the sustained parts of complex sounds improved with PMOD.

**Known-wrong (user-reported, by ear):**
- **PK/PSI Rockin** — the **initial/attack** sounds wrong (the sustain is closer).
- **Battle-swirl** — the rising whoosh (a pitch sweep) plays but sounds off.
- **Enemy-death** — plays but wrong.
- **UFO attack** — plays but wrong.
- **"Went up in flames"** (Territorial Oak death) — plays but wrong. Fire/static SFX
  typically use the **noise generator (NON / LFSR)** → a strong hint the noise path is off.
- **Spinning robo** — plays but wrong.
- **Franklin Badge** (lightning reflect) — plays but wrong.
- **Menu "click into" (select) sound** — wrong (deep). But the menu-cursor-**move** sound
  (high-pitch) is **CORRECT**.
- **"Tessie has been sighted" (song) — the WIND element sounds LOW + DISTORTED, should be
  HIGH-pitched.** A high element rendering *low* = the PITCH itself is mis-computed, not just
  interpolation. Best concrete test case for the PCM-diff rig (a real song with a known-wrong
  high element; a synthetic low tone MATCHED snes_spc, so the bug is elsewhere — likely the
  VxPITCH step / pitch-counter or high-pitch resample/aliasing, not the low-pitch Gaussian).

**⭐ KEY CLUE (2026-07-07): high-pitch sounds are RIGHT, deep/low-pitch sounds are WRONG.**
The menu cursor-move (high) is correct; the menu-select (deep) is wrong. This strongly
implicates the **low-pitch reproduction path**: the **4-tap Gaussian interpolation** (which
does heavy work at low pitch — many interpolated output samples per input sample; a
high-pitch voice barely interpolates) and/or the **VxPITCH resample stepping / pitch
counter** at low rates. Prime suspect for the whole systematic bug — check the Gaussian
table indexing + the pitch-counter fraction bits against fullsnes. This is exactly what the
PCM-diff rig should confirm (a low-pitch tone will diverge; a high one won't).

**This is systematic, not N separate bugs.** With this many SFX wrong across enemies, the
cause is a shared DSP-synthesis inaccuracy (pitch/resample rate, envelope, or noise clock).
The fix is almost certainly one root cause — find it with a PCM-diff against a reference
(task 3 below), not by ear-tweaking each SFX. Do NOT ship per-SFX DSP guesses.

The pattern: **rich/modulated/swept SFX** are the failures, which points at the pitch +
attack-envelope + modulation + **noise** path, not the basics. The flames clue elevates the
**noise generator (NON $3D, the LFSR rate/output)** to a prime suspect alongside the attack
envelope.

> **⚠️ Gate (2026-07-06):** a PMOD "refinement" that clamped the post-envelope sample to
> ±0x4000 **halved all audio** and shipped unverified (audio can't be heard headless) —
> reverted (`bbc587e`). **No further DSP change lands without the audio-output regression
> test below.** Rendering + an amplitude/PCM check would have caught it instantly.

## The frontier — DSP synthesis accuracy

The remaining fidelity gaps, in likely order for the reported bugs:
- **ADSR *attack* envelope** — the PK-Rockin *initial* is wrong while its sustain is
  right → the attack rate/curve is the prime suspect.
- **Pitch / VxPITCH resample + Gaussian at high pitch** — a rising sweep (swirl) stresses
  the per-sample pitch step + interpolation + BRR loop/end.
- **PMOD exactness** — the factor calc + clamp + sweep crop just landed; confirm it's
  exactly to fullsnes and only affects PMON voices.
- **Noise (NON) LFSR** — rate/output, if a SFX uses noise.
- **BRR filter modes 0-3** + loop/end edge cases.

## Delegatable tasks (pick one)

1. **ADSR attack accuracy** — verify the attack/decay/sustain/release rate tables + the
   envelope stepping against the anomie/fullsnes S-DSP spec; target the PK-Rockin *attack*.
2. **Pitch/resample fidelity** — the VxPITCH step, Gaussian table indexing at high pitch,
   BRR loop-point handling (targets the swirl sweep).
3. **A PCM-diff harness against a reference** (`snes_spc` / Mesen2): render a known SFX/song
   to WAV in both, diff the PCM. This is the *ungameable* oracle for this track (ears are
   the fun metric; PCM-diff is the honest one) — `docs/audio.md` calls for it.
4. **The `spc_dsp1-6` test ROMs** — drive them + read what each checks; some exercise
   exactly these paths.

Each DSP change: `make test` green + it must **not regress working audio** (clamp, no
wrap) and **needs a live listen** — SFX quality is the user's ears.

## Definition of done

- [ ] PK Rockin, battle-swirl, and enemy-death sound correct (user confirm).
- [ ] A PCM-diff against a reference renderer is within tolerance for a test song + SFX.
- [ ] The `spc_dsp` test ROMs the emulator can reach pass (non-cycle-accuracy ones).

## Related

`docs/audio.md` (the S-DSP + SPC700 foundation), `docs/music.md` (the jukebox / song
trigger), `docs/accuracy.md` (test ROMs). The DSP core also slots into the main emulator.
