# Bug: half-speed music in `make play`

**Status:** WORKAROUND — stay on known-good audio path (`0bdad72` or equivalent).  
**Filed:** 2026-07-08  
**Related:** `docs/audio.md` (APU/DSP pipeline), `docs/sfx.md` (synthesis fidelity — different track).

## Symptom

While playing (`make play` / live APU → slappy OpenAL stream):

- **Music feels half-speed** (tempo drag; sometimes described as pitch+tempo together).
- **Game video often still looks full speed** (~60 fps title bar / normal walk speed).
- Not the same as “no audio”, black force-blank hang, or individual SFX sounding wrong
  (those are other bugs — hang is timer/handshake; SFX wrongness is `docs/sfx.md`).

Bad “fixes” that made things worse when tried:

- `AL_PITCH = 2` on the OpenAL source — can *sound* faster but **underruns/glitches**
  (consumes PCM twice as fast as we produce ~32 k samples/s).
- Changing `SamplesPerFrame`, `frequency = 64000`, or other stream math while the
  real fault was **SPC timer0 tempo**.

## Intended (correct) audio coupling

On the known-good player path these are **already correct** and must not be
“fixed” blindly:

| Piece | Value | Role |
|--------|--------|------|
| OpenAL stream | `32000` Hz, stereo 16-bit | Playback clock (`newStreamingSource`) |
| Per emu frame | `32000 div 60` = **533** samples | PCM queued per frame |
| APU step | 2× `tickApu` per scanline + top-up to 533 | SPC + **timer0** + DSP advance |
| Wall pacing | `frameAcc` @ 60 Hz | ~60 emu frames / wall-second → ~32 kHz into OpenAL |

So half-speed music with full-speed video is **not** explained by a wrong
`32000` constant on the good commit — that table was already consistent.

## Two clocks (do not conflate)

EarthBound music uses:

1. **Sequence tempo** — SPC **timer 0** (`$FA` target, `$FD` counter). Driver
   spins on `MOV A,$FD` / `BEQ` (e.g. around APU `$0579`). This paces the song.
2. **Note pitch** — S-DSP **VxPITCH** (BRR resample rate per voice).

| What you hear | Failure mode |
|---------------|--------------|
| Song slow; notes roughly OK pitch | Timer0 tempo (period / resets / wrong target) |
| Everything low *and* slow | PCM played half-rate (OpenAL format/rate/pitch), or content stretched |

Reports during 2026-07-08 mixed both under “half-speed music.”

## Root cause (best current model)

### Primary (latest episode — fixed by checkout to `0bdad72`)

**SPC timer0 was not free-running at the rate the music driver expects.**

While fixing the battle/door **force-blank hang** (CPU `$C0:AB8A` wait on `$2140`,
SPC at `$0579` wait on `$FD`), experimental / uncommitted “live recovery”
re-armed T0 on `$FD` reads when the timer was disabled, and **zeroed**
`internal` / `counter` / `accum`.

Normal driver behavior clears ports via `$F1` writes that can **drop timer enable
bits**. Sequence:

1. Driver writes `$F1` with T0 enable clear (port clear).
2. Driver polls `$FD` (tight loop at ~`$0579`).
3. Recovery force-enables T0 but **resets the timer accumulators**.
4. Repeat during music / transitions → effective `$FD` tick rate collapses →
   **sequence tempo slows** while the PPU frame loop still hits ~60 fps.

Checkout of **`0bdad72`** (no live `$FD` re-arm) restored normal music speed.

### Secondary (load-state only)

Save blobs historically **omit** APU timer regs (`$F1`, `$FA`–`$FC`). After load,
T0 stays disabled → hang (not half-speed). `recoverTimersAfterLoad` re-enables T0
using APU RAM `$53` (FA shadow) or `$10`. That unsticks handshakes but can
**skew tempo after a load** if `$53` is wrong for that state. It does **not**
explain a clean cold boot with no state load.

### Earlier (already reverted) — different bug, same words

Commit **`1b37b4f`** rolled back an **NMI / scanline / RDNMI** stack
(`setScanline`, `raiseNmi`, real `$4210` flag, etc.) that **broke audio tempo and
play stability**. That is **frame/vblank wait coupling**, not OpenAL sample-rate
math. It is **not** what differs between good `0bdad72` and later half-speed
reports on master tip — that NMI stack was already gone by `0bdad72`.

### Ruled out as the main `0bdad72`↔tip delta

Git: `0bdad72` → `d4efef8` does **not** change:

- `SamplesPerFrame` / `32000` / stereo stream setup in `play.nim`
- DSP pitch path blob (same as restore-era DSP)

So “someone set 16 kHz” is **not** the story for that range.

## Commits / ranges

Full hashes are on the current history as of 2026-07-08. Short SHAs below.

### Known-good (audio stream + tempo OK for play)

| Commit | Subject | Notes |
|--------|---------|--------|
| **`0bdad7275291ecd881bb585a4c1ba49859f3f86b`** | Restore visual fixes without breaking audio: Mode 7 + battle UI PPU | **User-confirmed good** (2026-07-08 evening). Keep play APU→slappy path sacred. |
| **`1b37b4fa52c99eea456ae31d6d92bbac6ed12e75`** | Revert emulator core to eb3f714 — restore working audio/play | Explicit restore after NMI/timer stack broke **audio tempo**. |
| **`eb3f714fe313ae29e87f2b38177e23f62bb6c166`** | ppu: mode 0 ignores BGMODE bit 3… | Morning-of-2026-07-08-style core target of that revert (post DSP bit-exact). |
| **`0b1af45c2aa0e847187a641c1edbf48c662bab84`** | stabilize: reset audio-path files to known-good | Earlier “don’t concurrent-edit apu/snesbus/play” reset. |

### Related / partial (hang fix; tempo risk if extended live)

| Commit | Subject | Notes |
|--------|---------|--------|
| **`57fbb9727431be04de6a502bb602e286d7c8250c`** | Fix battle/door force-blank hang: recover APU timers on load | Adds `recoverTimersAfterLoad` + port echo on **deserialize only**. Needed for load hang; do **not** promote to every `$FD` read with accum zero. Also disables HDMA auto-capture (felt like lock). |
| **`d4efef8a5118cfe19623a169750d5169cca66999`** | llm-play: Pokey % seed e2e… | On master tip above `57fbb97`; **no** play sample-rate change. Half-speed reports on top of this were consistent with dirty live-timer recovery, not this commit’s llm-play diff. |

### Broken era (audio tempo) — do not re-land as-is

| Range / change | What went wrong |
|----------------|-----------------|
| Pre-`1b37b4f` NMI/scanline stack (`setScanline` / `raiseNmi` / nmiFlag RDNMI, etc.) | Broke **audio tempo** and play stability; fully reverted in `1b37b4f`. |
| Uncommitted live `$FD` re-arm that zeros T0 accum (2026-07-08 hang work) | Collapses music **tempo** while video stays ~60 fps; **not** on `0bdad72`. |
| `AL_PITCH = 2` / sample-rate hacks on the stream | Masks or fights symptoms; underruns; **do not use**. |

### Not this bug

| Commit / area | Why |
|---------------|-----|
| **`e0fe5ba`** dsp half-**scale** (volume / BRR stored scale) | Amplitude, not playback tempo. |
| `docs/sfx.md` high-vs-low SFX wrongness | Synthesis / VxPITCH / Gaussian path — separate from stream half-speed. |

## Regression tests

ROM-free unit tests lock the good contracts (no OpenAL, no gold ROM):

```text
nim r tests/test_audio_tempo.nim
# or: make test  (picks up tests/test_*.nim)
```

| Block | What it locks |
|--------|----------------|
| `playStreamContracts` | `32000/60=533`, 2×262=524 top-up, stereo byte sizes, `CyclesPerSample=32` |
| `timer0FreeRunRate` | T0 target `$10` → ~1 `$FD` tick per 64 samples (~100 in 6400); half-speed lands ~50 |
| `timer0PollDoesNotKillTempo` | Polling `$FD` while enabled does not restart accum (two windows same rate) |
| `timer0DisableStaysOff` | Disabled T0 → `$FD` always 0 |
| `timer0ReenableViaF1RestoresRate` | Correct recovery is **F1 re-enable**, not inventing ticks while off |

Optional (ROM present, existing): `tests/test_dsp_output.nim` — silence smoke only, not tempo.

## How to verify (if it returns)

Without changing the stream constants:

1. Run `nim r tests/test_audio_tempo.nim` — must pass on the good commit.
2. Title bar / `frameCount` Δ ≈ **60** emu frames per wall second.
3. Samples queued/sec ≈ **32000** stereo frames (60 × 533).
4. OpenAL buffer drain ≈ production (queue depth not growing unboundedly).
5. SPC timer0: enabled, target ≈ driver FA / `$53`, **not** reset every `$FD` poll.
6. Optional: render the same APU path to WAV @ 32 kHz offline — if WAV tempo is correct and live play is slow, suspect OpenAL/host; if WAV is slow too, suspect timer0 / sample generation coupling.

## Rules for future fixes

**Do**

- Treat `0bdad72` play audio path as the reference (32 kHz stereo, 533 samples/frame, 2 ticks/line).
- Fix battle/door hang with **load-time** timer restore and/or **serializing** real `$F1`/`$FA`–`$FC` in save states.
- Port-echo resync only when CPU is clearly stuck in `$C0:AB8x` handshake.

**Don’t**

- Re-arm T0 on every `$FD` read and zero accumulators.
- “Fix” half-speed with `AL_PITCH`, fake sample rates, or doubling `SamplesPerFrame` without measuring timer0 vs wall clock.
- Concurrent-edit `apu` / `snesbus` / `dsp` / `play` across agents (see `0b1af45` lesson).

## Safe hang fix (landed after known-good bookmark)

Save-state **v2** stores timer0..2 + `dspAddr`. **v1** loads still call
`recoverTimersAfterLoad` (enable T0 from `$53`/`$10`) — **only on deserialize**,
never on live `$FD` polls. Tests: `tests/test_save_state.nim`,
`tests/test_audio_tempo.nim`.

## One-line summary

**Half-speed music (with full-speed video) was SPC timer0 tempo getting reset or wrong — not a broken 32 kHz slappy setup on the good commit.** Stay on `0bdad72`-class audio path; re-land hang fixes only as load-time / serialized timers, never live `$FD` accum resets.
