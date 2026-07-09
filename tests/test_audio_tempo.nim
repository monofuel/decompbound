## Regression locks for half-speed music / play audio coupling.
## See docs/half-speed-music.md. ROM-free: pure APU timer math + play contracts.
## Does not open OpenAL or require the gold ROM.

import
  std/strformat,
  decompbound/apu

const
  ## Must match src/tools/play.nim (and jukebox_app) live stream setup.
  SampleRate = 32000
  Fps = 60
  SamplesPerFrame = SampleRate div Fps
  ScanlinesPerFrame = 262
  ApuTicksPerScanline = 2
  StereoBytesPerSample = 4  ## int16 left + int16 right

block playStreamContracts:
  ## Lock the known-good play path numbers (0bdad72-class). Changing these
  ## without measuring wall-clock samples/sec is how half-speed / underruns return.
  doAssert SamplesPerFrame == 533, "play SamplesPerFrame must stay 32000/60"
  doAssert CyclesPerSample == 32, "SPC cycles per 32kHz sample (1.024MHz/32k)"
  doAssert ScanlinesPerFrame * ApuTicksPerScanline == 524,
    "2 ticks/line * 262 lines — play tops up 524→533"
  doAssert ScanlinesPerFrame * ApuTicksPerScanline < SamplesPerFrame,
    "top-up loop required so OpenAL gets a full frame"
  doAssert SamplesPerFrame * StereoBytesPerSample == 2132,
    "stereo s16 PCM bytes per frame queued to slappy"
  doAssert SampleRate * StereoBytesPerSample == 128_000,
    "bytes per wall-second at real-time"

proc enableTimer0(apu: Apu, target: uint8 = 0x10) =
  ## Program FA then F1 bit0 like the EB driver init path.
  doAssert apu.spc.writeHook != nil
  discard apu.spc.writeHook(0x00FA, target)
  discard apu.spc.writeHook(0x00F1, 0x01)

proc disableTimers(apu: Apu) =
  ## F1 with timer enable bits clear (port-clear style).
  discard apu.spc.writeHook(0x00F1, 0x00)

proc countFdTicks(apu: Apu, samples: int): int =
  ## Run `samples` of runSample, reading $FD every sample (clears counter).
  ## Returns sum of non-zero $FD values (≈ number of timer0 overflows if we
  ## poll every sample and never miss a multi-tick gap).
  doAssert apu.spc.readHook != nil
  result = 0
  for _ in 0 ..< samples:
    discard apu.runSample()
    let v = apu.spc.readHook(0x00FD)
    if v > 0:
      result += v

block timer0FreeRunRate:
  ## Hardware: T0 stage1 every 128 SPC cycles; one runSample = 32 cycles →
  ## stage1 every 4 samples. target=$10 (16) → counter++ every 16*4 = 64 samples.
  ## 6400 samples → expect ~100 overflows if T0 free-runs (not reset each poll).
  const
    Target = 0x10'u8
    Samples = 6400
    Expected = Samples div (16 * (128 div CyclesPerSample))  # 6400/64 = 100
  doAssert Expected == 100
  let apu = newApu()
  enableTimer0(apu, Target)
  let ticks = countFdTicks(apu, Samples)
  # Allow ±5% for any off-by-one at edges; half-speed tempo would land ~50.
  doAssert ticks >= 95 and ticks <= 105,
    &"timer0 free-run wrong: got {ticks} $FD ticks in {Samples} samples (want ~{Expected}). " &
    "Half-speed music often means T0 is being reset or disabled while the driver polls $FD " &
    "(see docs/half-speed-music.md)."

block timer0PollDoesNotKillTempo:
  ## Polling $FD while T0 is *enabled* must only clear the 4-bit counter, not
  ## restart the stage1/stage2 accumulators. Two back-to-back windows at the
  ## same rate proves live "$FD re-arm + zero accum" regressions stay gone.
  const
    Window = 3200
    Expected = Window div 64  # 50
  let apu = newApu()
  enableTimer0(apu, 0x10)
  let a = countFdTicks(apu, Window)
  let b = countFdTicks(apu, Window)
  doAssert a >= Expected - 3 and a <= Expected + 3, &"window A ticks={a} want~{Expected}"
  doAssert b >= Expected - 3 and b <= Expected + 3, &"window B ticks={b} want~{Expected}"
  doAssert abs(a - b) <= 3, &"tempo drifted between windows: {a} vs {b}"

block timer0DisableStaysOff:
  ## With T0 disabled, $FD must stay 0. (Hang fix must re-enable via F1 / load
  ## path — not by inventing ticks while disabled.)
  let apu = newApu()
  enableTimer0(apu, 0x10)
  discard countFdTicks(apu, 128)
  disableTimers(apu)
  let ticks = countFdTicks(apu, 2000)
  doAssert ticks == 0,
    &"disabled T0 still produced {ticks} $FD ticks — timer enable bit ignored?"

block timer0ReenableViaF1RestoresRate:
  ## Correct recovery path: F1 bit0 back on (driver or load-time helper).
  ## Rate after re-enable must match free-run again.
  const Window = 3200
  let apu = newApu()
  enableTimer0(apu, 0x10)
  discard countFdTicks(apu, 256)
  disableTimers(apu)
  doAssert countFdTicks(apu, 256) == 0
  enableTimer0(apu, 0x10)
  let ticks = countFdTicks(apu, Window)
  let expected = Window div 64
  doAssert ticks >= expected - 3 and ticks <= expected + 3,
    &"after F1 re-enable got {ticks} want~{expected}"
