## DSP audio output regression smoke (part of suite when gold ROM present).
## Full amplitude gate lives in src/tools/audio_check.nim (run via make audio-check
## or nim c -r). This test ensures the *play* collection path produces audio
## (catches total silence) and that sample counts match the known-good stream
## coupling (533 stereo frames/frame including top-up). Fast: short frame count.

import
  std/[os, strformat, math],
  decompbound/[cpu, snesbus]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  ShortFrames = 120  # early boot; still produces init audio per probes (nz>0)
  InstrPerLine = 150
  SamplesPerFrame = 32000 div 60  # play.nim
  Scanlines = 262
  ApuTicksPerLine = 2

proc readRomFile(filepath: string): seq[uint8] =
  ## Load ROM bytes, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc computeStats(samples: seq[int16]): tuple[peakL, peakR: int, rmsL, rmsR: float, nonzero: int] =
  ## Peak / RMS / nonzero stereo sample stats for smoke asserts.
  var sumSqL = 0.0
  var sumSqR = 0.0
  var pkL = 0
  var pkR = 0
  var nz = 0
  let n = samples.len div 2
  if n == 0:
    return (0, 0, 0.0, 0.0, 0)
  for i in 0..<n:
    let lv = samples[i * 2].int
    let rv = samples[i * 2 + 1].int
    let al = abs(lv)
    let ar = abs(rv)
    if al > pkL: pkL = al
    if ar > pkR: pkR = ar
    sumSqL += float(lv * lv)
    sumSqR += float(rv * rv)
    if al != 0 or ar != 0: inc nz
  let rmsL = sqrt(sumSqL / float(n))
  let rmsR = sqrt(sumSqR / float(n))
  (pkL, pkR, rmsL, rmsR, nz)

block dspSmoke:
  ## Collect PCM the way play does (2 ticks/line + top-up to 533).
  if not fileExists(GoldMasterRom):
    echo "[test_dsp_output] no gold ROM present; skipping audio smoke"
  else:
    echo "[test_dsp_output] ROM present; running short smoke collect"
    let rom = readRomFile(GoldMasterRom)
    let snes = newSnesBus(rom)
    var cpu = snes.resetCpu()
    snes.initHdma()
    var samples: seq[int16] = @[]
    for f in 0 ..< ShortFrames:
      var smp = 0
      var l = 0
      while l < Scanlines:
        if l == 224 and (snes.nmitimen and 0x80) != 0:
          cpu.nmiPending = true
        for i in 0 ..< InstrPerLine:
          cpu.step(snes.bus)
          if cpu.stopped: break
        for k in 0 ..< ApuTicksPerLine:
          let (left, right) = snes.tickApu()
          samples.add(left)
          samples.add(right)
          smp += 1
        inc l
        if l >= Scanlines:
          snes.initHdma()
          break
      # Play top-up: 262*2=524 < 533.
      while smp < SamplesPerFrame:
        let (left, right) = snes.tickApu()
        samples.add(left)
        samples.add(right)
        smp += 1
      doAssert smp == SamplesPerFrame,
        &"frame {f}: produced {smp} samples, want {SamplesPerFrame}"

    let stereoFrames = samples.len div 2
    doAssert stereoFrames == ShortFrames * SamplesPerFrame,
      &"total stereo frames {stereoFrames} != {ShortFrames}*{SamplesPerFrame}"
    let (pkL, pkR, rmsL, rmsR, nz) = computeStats(samples)
    doAssert samples.len > 1000, "no samples collected"
    doAssert nz > 0, "total silence in short run (DSP or APU path dead)"
    doAssert pkL >= 0 and pkR >= 0, "peak underflow"
    echo &"[test_dsp_output] smoke ok: frames={ShortFrames} stereo={stereoFrames} " &
      &"nz={nz} peak={pkL}/{pkR} rms={rmsL:.1f}/{rmsR:.1f}"
