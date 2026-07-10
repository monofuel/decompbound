## Referee lock: loading a v1 save-state must restore music TEMPO, end to end.
## The 2026-07-09 regression restored T0's target from SPC RAM $53 (a drifting
## driver variable) — every v1 load then played music at ~half speed while all
## unit contracts still passed. This test loads the real fixture and measures
## the actual free-running T0 rate after load.
## Skips quietly when the user ROM / fixture state are absent (CI without ROM).

import
  std/[os, strformat],
  ../src/decompbound/[cpu, snesbus, save_state, apu]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  FixtureState = "bin/states/llm/onett_start.state"
  ## EB driver constant divisor: FA=$10. The 8kHz stage bumps `internal` once
  ## per 4 samples (128 cycles / 32 cycles-per-sample); internal wraps at the
  ## target → every 16 bumps = every 64 samples at 32kHz.
  Samples = 16_000
  ExpectedWraps = Samples div 64  # 250
  ## Half-tempo failure (e.g. restored target 0x1F) lands near 129 wraps.
  MinWraps = ExpectedWraps - 30
  MaxWraps = ExpectedWraps + 30

proc readRom(path: string): seq[uint8] =
  ## ROM bytes, stripping an optional 512-byte copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc main() =
  ## Load the fixture and assert T0 target + measured wrap rate.
  if not fileExists(RomPath) or not fileExists(FixtureState):
    echo "[test_state_load_tempo] skipped (ROM or fixture state absent)"
    return
  let snes = newSnesBus(readRom(RomPath))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FixtureState)), snes, c)

  let t0 = snes.apu.getTimerSnapshot(0)
  doAssert t0.enabled, "T0 must be enabled after load"
  doAssert t0.target == 0x10,
    &"T0 target after v1 load must be the driver constant 0x10 (got 0x{t0.target:02X})"

  # Measure the free-running rate: count internal-counter wraps over Samples.
  var wraps = 0
  var prev = snes.apu.getTimerSnapshot(0).internal
  for _ in 0 ..< Samples:
    discard snes.apu.runSample()
    let cur = snes.apu.getTimerSnapshot(0).internal
    if cur < prev:
      inc wraps
    prev = cur
  doAssert wraps >= MinWraps and wraps <= MaxWraps,
    &"T0 rate off after load: {wraps} wraps in {Samples} samples " &
    &"(want ~{ExpectedWraps}; ~129 means the 0x1F half-speed regression)"

  echo &"[test_state_load_tempo] ok: T0 target=0x10, {wraps} wraps in {Samples} samples (~{ExpectedWraps} expected)"

when isMainModule:
  main()
