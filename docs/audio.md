# Audio

How Earthbound audio works, and how we get to *hearing it* long before the
emulator exists. This is a standalone track (call it Goal 2a): it shares no
code with the 65816 asm/disasm work, so it can proceed in parallel without
blocking or being blocked.

## The key fact

The SNES audio subsystem (APU) is a fully self-contained computer:

- **SPC700** — an 8-bit CPU with its own 64KB of RAM,
- **S-DSP** — the mixer/synth chip (8 voices, BRR samples, ADSR, echo),
- connected to the main SNES by just **four I/O ports**.

The music driver, sequence data, and all samples get uploaded into APU RAM by
the game, and then the APU runs independently. This is why the `.spc` file
format exists: snapshot the 64KB RAM + register state mid-song, and a
standalone player reproduces the music with **zero** 65816/PPU/cartridge
emulation.

So "hear Onett" = an SPC player in Nim. No SNES emulator required.

## True SNES audio (the SPC player)

### Components

1. **`.spc` snapshots** — dump from the gold ROM with a reference emulator
   (e.g. Mesen2) for clean provenance. One 64KB+registers file per song.
2. **SPC700 CPU core** — ~256 opcodes, pure 8-bit. Genuinely easier than the
   65816 (no M/X flag-width madness). Plus timers and the 4 I/O ports, which
   mostly idle in a standalone player.
3. **S-DSP** — the real work:
   - BRR sample decoding (4-bit ADPCM, 9-byte blocks),
   - 8 voices with pitch scaling,
   - ADSR envelopes,
   - mix to 16-bit stereo at 32kHz.
4. **Output** — 16-bit PCM. WAV file first, realtime later (see slappy below).

### Earthbound-specific honesty

A first-pass DSP gets you *recognizable* Earthbound. Two refinements that are
usually deferred are **not optional here** for it to *sound like* Earthbound:

- **Echo / FIR filter** — EB leans on the echo buffer hard (the Onett reverb,
  battle theme spaciousness). Expect the first playback to sound dry; that is
  expected, not failure.
- **Gaussian interpolation** — the SNES's characteristic soft sample
  interpolation (4-tap table). Without it, output sounds slightly crunchy.

Both are exhaustively documented (fullsnes; blargg's `snes_spc` is the
reference implementation to check behavior against).

### Verification (keeping it ungameable)

- **SPC700 core:** TomHarte SingleStepTests has per-instruction JSON test
  vectors (initial state -> expected final state). Same crisp, parallelizable,
  agent-friendly verification as the 65816 core. (Verify vector coverage
  before relying on it.)
- **DSP:** render to WAV and PCM-diff against a reference renderer
  (`snes_spc`, Mesen2). Ears are the fun metric; PCM diff is the honest one.
- WAV-first rendering means agents can produce and verify audio headlessly,
  with no audio device.

### Why this feeds the main project

- The SPC700 + DSP cores slot directly into the Goal 2 emulator later (audio
  was its "long tail" — this pulls it forward).
- Once fluent in how the driver plays sequences from APU RAM, the ROM-side
  music engine (how EB uploads songs to the APU) becomes a natural
  decompilation target with a working test bed.

## Easy slappy example tools

[slappy](https://github.com/treeform/slappy) (local checkout: `../slappy`) is
monofuel + treeform's OpenAL sound library. Surveyed 2026-07-03:

### What works today (zero slappy changes)

- Loads `.wav` / `.ogg` into OpenAL buffers; plays with gain/pitch/3D/looping.
- The WAV loader handles 16-bit PCM at arbitrary sample rates — exactly what
  the DSP outputs (16-bit stereo @ 32kHz).
- So the first milestone tool is: **SPC -> render offline -> write WAV ->
  `newSound("onett.wav").play()`**. Works with slappy as it sits.

### Tool ideas (in rough order)

1. `spc_render` — SPC file in, WAV file out. The workhorse: listening,
   PCM-diffing, CI artifacts. No audio device needed.
2. `spc_play` — render a full song loop into one buffer up front, play with
   `looping = true`. Realtime-feeling jukebox with zero streaming machinery.
3. `spc_jukebox` — true realtime streaming (live channel muting, gapless
   infinite loops). **Requires finishing slappy's queued-buffers feature**:
   the `Source` type already has a `queuedBuffers: seq[ALuint]` field and the
   README lists queueing as "(in progress)", but the
   `alSourceQueueBuffers`/`alSourceUnqueueBuffers` loop never landed (~50
   lines). That's an upstream slappy contribution, not a workaround.

### Non-goals for the audio track

- Cycle-accurate APU timing beyond what makes EB songs sound right.
- General-purpose SPC player features (other games' quirks).
- Blocking Goal 1 (asm/disasm) work — this track is parallel, morale-driven,
  and proud of it.
