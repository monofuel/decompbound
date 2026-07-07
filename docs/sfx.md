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
- **PK/PSI Rockin** — the *sustained/end* "crackly bit" improved (PMOD), but the
  **initial/attack** sounds are still wrong.
- **Battle-swirl** — the rising whoosh (a pitch sweep) plays but sounds off.
- **Enemy-death** — plays but wrong.

The pattern: **rich/modulated/swept SFX** are the failures, which points at the pitch +
attack-envelope + modulation path, not the basics.

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
