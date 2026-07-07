## Audio-output regression harness/test for the S-DSP (the gate for all future
## DSP/SFX work per docs/sfx.md). Boots the ROM (headless), runs N frames of
## the full emulator (title/intro music or user state), collects every stereo
## sample exactly as the real audio path does via tickApu() -> dsp.mixSample(),
## computes PEAK and RMS on both channels, asserts amplitude is in a sane band
## (catches silence or halving like the +/-0x4000 clamp regression), and writes
## the PCM to bin/audio_check.wav (gitignored) for listening or future diffs.
##
## Bonus: --load-state <N|path> lets you start from a save-state (e.g. one
## captured where a specific SFX is active) and render just that audio snippet
## headlessly.
##
## Constraints: new file only. Does not touch dsp.nim, play.nim, ppu, core
## render paths, or add non-minimal Makefile changes.
##
## Run: nim c -r src/tools/audio_check.nim [--frames N] [--load-state <slot|foo.state>] [rom]
##      make audio-check   (after the minimal target is added)

import
  std/[os, strformat, strutils, math, options],
  ../decompbound/[cpu, save_state, snesbus]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultFramesBoot = 1400   # reaches title/attract music with healthy amplitude
  DefaultFramesLoaded = 400  # from a music/sfx state, shorter is enough
  SampleRate = 32000
  # Baseline captured on current good DSP (1400f boot run). These are printed
  # at end of each run so we can re-bake when ranges legitimately grow.
  # Halved output (the known regression class) must fail these floors.
  MinPeak = 3000   # observed min-channel ~4396 at 1400f; half ~2200 < 3000 -> FAIL
  MinRms = 250     # observed ~435-478; provides secondary guard

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file, stripping optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc writeWav(path: string, samples: seq[int16]) =
  ## Write interleaved stereo 16-bit 32kHz PCM to a RIFF WAV (little endian).
  ## Output path must be gitignored (e.g. under bin/).
  var header = newSeq[uint8](44)
  let dataSize = samples.len * 2
  let fileSize = 36 + dataSize

  proc put32(offset: int, value: int) =
    header[offset] = (value and 0xFF).uint8
    header[offset + 1] = ((value shr 8) and 0xFF).uint8
    header[offset + 2] = ((value shr 16) and 0xFF).uint8
    header[offset + 3] = ((value shr 24) and 0xFF).uint8

  proc put16(offset: int, value: int) =
    header[offset] = (value and 0xFF).uint8
    header[offset + 1] = ((value shr 8) and 0xFF).uint8

  header[0..3] = @[0x52'u8, 0x49, 0x46, 0x46]
  put32(4, fileSize)
  header[8..11] = @[0x57'u8, 0x41, 0x56, 0x45]
  header[12..15] = @[0x66'u8, 0x6D, 0x74, 0x20]
  put32(16, 16)
  put16(20, 1)  # PCM
  put16(22, 2)  # stereo
  put32(24, SampleRate)
  put32(28, SampleRate * 4)
  put16(32, 4)
  put16(34, 16)
  header[36..39] = @[0x64'u8, 0x61, 0x74, 0x61]
  put32(40, dataSize)

  var output = newString(44 + dataSize)
  for i, b in header:
    output[i] = b.char
  for i, s in samples:
    output[44 + i * 2] = (s.uint16 and 0xFF).char
    output[45 + i * 2] = (s.uint16 shr 8).char
  writeFile(path, output)

proc computeStats(samples: seq[int16]): tuple[peakL, peakR: int, rmsL, rmsR: float, nonzero: int] =
  ## Return peak abs and RMS for left and right channels independently.
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

proc loadStateArg(snes: SnesBus, cpu: var Cpu, arg: string) =
  ## Load either a numeric slot (bin/states/slotN.state) or an explicit .state path.
  let slotOpt = try: some(parseInt(arg)) except: none(int)
  if slotOpt.isSome:
    let slot = slotOpt.get
    echo &"loading state from slot {slot}"
    loadState(snes, cpu, slot)
  else:
    if not fileExists(arg):
      echo &"ERROR: --load-state path not found: {arg}"
      quit(1)
    echo &"loading state from file: {arg}"
    let data = cast[seq[byte]](readFile(arg))
    deserializeState(data, snes, cpu)

proc runFramesCollect(snes: SnesBus, cpu: var Cpu, numFrames: int): seq[int16] =
  ## Run exact N frames using the canonical per-line budget + NMI + APU tick
  ## timing used by play.nim (InstrPerLine=150). Collect every stereo sample.
  ## Returns interleaved L/R int16 PCM. Does not render graphics.
  const InstrPerLine = 150
  var samples = newSeq[int16]()
  var f = 0
  while f < numFrames and not cpu.stopped:
    var l = 0
    while l < 262:
      if l == 224 and (snes.nmitimen and 0x80) != 0:
        cpu.nmiPending = true
      for i in 0..<InstrPerLine:
        cpu.step(snes.bus)
        if cpu.stopped:
          break
      for k in 0..<2:
        let (left, right) = snes.tickApu()
        samples.add(left)
        samples.add(right)
      inc l
      if l >= 262:
        snes.initHdma()
        break
    inc f
  samples

proc main() =
  ## Parse CLI, boot or load state, run, measure, assert sane audio, write WAV.
  var romPath = DefaultRom
  var framesOverride = 0
  var loadStateArgVal = ""
  var outPath = "bin/audio_check.wav"
  var argIdx = 1
  if paramCount() >= 1 and paramStr(1) == "--":
    argIdx = 2
  while argIdx <= paramCount():
    let a = paramStr(argIdx)
    if a == "--frames" and argIdx < paramCount():
      inc argIdx
      framesOverride = parseInt(paramStr(argIdx))
    elif a.startsWith("--frames="):
      framesOverride = parseInt(a[9 .. ^1])
    elif a == "--load-state" and argIdx < paramCount():
      inc argIdx
      loadStateArgVal = paramStr(argIdx)
    elif a.startsWith("--load-state="):
      loadStateArgVal = a[13 .. ^1]
    elif a == "--out" and argIdx < paramCount():
      inc argIdx
      outPath = paramStr(argIdx)
    elif a.startsWith("--out="):
      outPath = a[6 .. ^1]
    elif not a.startsWith("--") and romPath == DefaultRom:
      # first non-flag non-rom is treated as rom only if still default
      if a.len > 0:
        romPath = a
    else:
      # ignore unknown for forward compat; or error
      if a != "--":
        echo &"unknown arg: {a}"
        quit(1)
    inc argIdx

  if not fileExists(romPath):
    echo &"ROM not found: {romPath}"
    echo "Supply your own legally dumped EarthBound ROM."
    quit(1)

  let loadDesc = if loadStateArgVal.len > 0: loadStateArgVal else: "(boot)"
  echo &"audio_check: ROM={romPath} loadState={loadDesc} framesOverride={framesOverride}"

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()

  if loadStateArgVal.len > 0:
    loadStateArg(snes, cpu, loadStateArgVal)

  let numFrames =
    if framesOverride > 0: framesOverride
    elif loadStateArgVal.len > 0: DefaultFramesLoaded
    else: DefaultFramesBoot

  echo &"running {numFrames} frames (collecting ~{numFrames * 2 * 262} samples) ..."
  let samples = runFramesCollect(snes, cpu, numFrames)

  if samples.len < 1000:
    echo "ERROR: too few samples collected; emulator may have stopped early"
    quit(1)

  let (peakL, peakR, rmsL, rmsR, nz) = computeStats(samples)
  let secs = float(samples.len div 2) / float(SampleRate)

  echo &"collected {samples.len} samples ({secs:.2f}s) nonzero={nz}"
  echo &"PEAK L/R: {peakL} / {peakR}"
  echo &"RMS  L/R: {rmsL:.1f} / {rmsR:.1f}"

  # Always write the WAV for manual audition + future reference capture.
  createDir("bin")
  writeWav(outPath, samples)
  echo &"wrote {outPath}"

  # Baseline print (update the Min* consts + comment when ranges change for real reasons).
  echo &"BASELINE peakL={peakL} peakR={peakR} rmsL={rmsL:.1f} rmsR={rmsR:.1f} (bake as expected range)"

  # Sane band checks. Primary guard is peak (halving bug directly scales peaks).
  let sane = (peakL >= MinPeak) and (peakR >= MinPeak) and
             (rmsL >= MinRms) and (rmsR >= MinRms) and
             (peakL <= 32767) and (peakR <= 32767)
  if not sane:
    echo "FAIL: audio amplitude outside sane band (near-silent or pathological)"
    echo &"  thresholds: peak>={MinPeak} rms>={MinRms}"
    # Demonstrate the halving sensitivity
    let halfL = peakL div 2
    let halfR = peakR div 2
    echo &"  halved would be ~{halfL}/{halfR} -> peak < MinPeak => FAIL (this is the point of the harness)"
    quit(1)

  echo "PASS: amplitude in sane band (not silent, not clipped)"
  # Show that a halved signal would have failed (for the report / future readers)
  let halfL = peakL div 2
  let halfR = peakR div 2
  if halfL < MinPeak or halfR < MinPeak:
    echo &"halving demo: half peak ~{halfL}/{halfR} < {MinPeak} would correctly FAIL the check"

when isMainModule:
  main()
