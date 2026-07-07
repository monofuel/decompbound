## PCM waveform diff oracle: render same .spc through our DSP (via APU) and
## blargg's reference snes_spc (--no-filter raw path), then analyze divergence.
## Used to localize systematic S-DSP bugs (pitch, envelope, noise, BRR/interp)
## by measurement rather than ear. See docs/sfx.md and docs/audio.md.
##
## New file only; does not modify any core (dsp.nim etc) or tests/.
## Modelled on audio_check.nim WAV + stats style.

import
  std/[os, osproc, strformat, strutils, math]

import ../decompbound/[apu, dsp]

const
  DefaultSpc = "/home/monofuel/Documents/Arcade/PSP/PSP/GAME/Snes9x_Euphoria/DATA/logo.spc"
  DefaultSeconds = 8.0
  DefaultSkip = 0.25
  SampleRate = 32000
  RmsTolerancePercent = 5.0
  WindowFrames = 1600  # ~50 ms at 32 kHz
  NumLogBins = 20

proc readRomFile(filepath: string): seq[uint8] =
  ## Read a binary file (no copier header stripping for .spc).
  let data = readFile(filepath)
  result = newSeq[uint8](data.len)
  for i in 0..<result.len:
    result[i] = data[i].uint8

proc writeWav(path: string, samples: seq[int16]) =
  ## Write interleaved stereo 16-bit 32kHz PCM to a RIFF WAV (little endian).
  ## Output path under bin/ (gitignored).
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

proc readWav(path: string): seq[int16] =
  ## Read interleaved stereo 16-bit PCM from a simple RIFF WAV we (or spc2wav) wrote.
  ## Assumes 44-byte header, 32kHz, no extra chunks.
  let data = readFile(path)
  if data.len < 44:
    echo &"ERROR: WAV too small: {path}"
    quit(1)
  let dataSize = (data[40].uint32 or
                  (data[41].uint32 shl 8) or
                  (data[42].uint32 shl 16) or
                  (data[43].uint32 shl 24)).int
  if dataSize <= 0 or (44 + dataSize) > data.len:
    echo &"ERROR: bad WAV data size in {path}"
    quit(1)
  let numSamples = dataSize div 2
  result = newSeq[int16](numSamples)
  for i in 0..<numSamples:
    let lo = data[44 + i * 2].uint8
    let hi = data[45 + i * 2].uint8
    result[i] = cast[int16](lo.uint16 or (hi.uint16 shl 8))

proc channelRms(samples: seq[int16], ch: int): float =
  ## RMS for one channel (0=L, 1=R) over interleaved stereo frames.
  var sum = 0.0
  let nframes = samples.len div 2
  if nframes == 0: return 0.0
  for i in 0..<nframes:
    let v = float(samples[i * 2 + ch])
    sum += v * v
  sqrt(sum / float(nframes))

proc channelRmsError(o, r: seq[int16], ch: int): float =
  ## RMS of (o - r) on one channel.
  var sum = 0.0
  let nframes = min(o.len, r.len) div 2
  if nframes == 0: return 0.0
  for i in 0..<nframes:
    let d = float(o[i * 2 + ch]) - float(r[i * 2 + ch])
    sum += d * d
  sqrt(sum / float(nframes))

proc dominantFreq(samples: seq[int16], startFrame: int, nframes: int, ch: int, sampleRate = SampleRate): float =
  ## Naive DFT power scan over ~log-spaced bins 100Hz..~8kHz. Returns dominant freq in Hz.
  ## Correctness over speed; small windows.
  if nframes < 64: return 0.0
  var bestF = 0.0
  var bestPower = 0.0
  for b in 0..<NumLogBins:
    let freq = 100.0 * pow(1.38, float(b))
    if freq > 8500.0: break
    var re = 0.0
    var im = 0.0
    for k in 0..<nframes:
      let s = float(samples[(startFrame + k) * 2 + ch])
      let ang = 2.0 * PI * freq * float(k) / float(sampleRate)
      re += s * cos(ang)
      im += s * sin(ang)
    let p = re * re + im * im
    if p > bestPower:
      bestPower = p
      bestF = freq
  bestF

proc windowRms(samples: seq[int16], startFrame, nframes: int, ch: int): float =
  var sum = 0.0
  if nframes <= 0: return 0.0
  for k in 0..<nframes:
    let v = float(samples[(startFrame + k) * 2 + ch])
    sum += v * v
  sqrt(sum / float(nframes))

proc main() =
  ## Parse args, load .spc into our APU (direct regs, hydrate voices), render ours,
  ## shell to spc2wav --no-filter (or with filter), read ref, diff + report.
  var spcPath = ""
  var seconds = DefaultSeconds
  var skipSec = DefaultSkip
  var applyFilter = false

  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--spc" and i < paramCount():
      inc i
      spcPath = paramStr(i)
    elif a.startsWith("--spc="):
      spcPath = a[6 .. ^1]
    elif a == "--seconds" and i < paramCount():
      inc i
      seconds = parseFloat(paramStr(i))
    elif a.startsWith("--seconds="):
      seconds = parseFloat(a[10 .. ^1])
    elif a == "--skip" and i < paramCount():
      inc i
      skipSec = parseFloat(paramStr(i))
    elif a.startsWith("--skip="):
      skipSec = parseFloat(a[7 .. ^1])
    elif a == "--filter":
      applyFilter = true
    elif a == "--help" or a == "-h":
      echo "Usage: nim r src/tools/audio_diff.nim --spc <path.spc> [--seconds N] [--skip 0.25] [--filter]"
      echo "  --filter : let ref use SPC_Filter (default: raw --no-filter for DSP-vs-DSP)"
      quit(0)
    else:
      if not a.startsWith("--") and spcPath.len == 0:
        spcPath = a
    inc i

  if spcPath.len == 0:
    spcPath = DefaultSpc
  if not fileExists(spcPath):
    echo &"ERROR: SPC not found: {spcPath}"
    echo "Provide --spc /path/to/something.spc or ensure default logo.spc exists."
    quit(1)

  if seconds <= 0.1 or seconds > 300:
    echo "ERROR: seconds out of range"
    quit(1)
  if skipSec < 0 or skipSec > seconds:
    echo "ERROR: skip out of range"
    quit(1)

  echo &"audio_diff: spc={spcPath} seconds={seconds} skip={skipSec} filterRef={applyFilter}"

  # --- PART B1: load snapshot into our APU (direct to regs, no write() calls) ---
  let spcData = readRomFile(spcPath)
  if spcData.len < 0x10180:
    echo &"ERROR: SPC too small ({spcData.len} bytes)"
    quit(1)

  # loose signature check (0x00-0x1A area)
  let expectedSig = "SNES-SPC700 Sound File Data v0.30"
  var sigOk = true
  for k in 0..<min(expectedSig.len, spcData.len):
    if spcData[k] != expectedSig[k].uint8:
      sigOk = false
  if not sigOk:
    echo "warning: SPC signature mismatch (proceeding)"

  let apu = newApu()

  let pc = (spcData[0x26].uint16 shl 8) or spcData[0x25].uint16
  apu.spc.pc = pc
  apu.spc.a = spcData[0x27]
  apu.spc.x = spcData[0x28]
  apu.spc.y = spcData[0x29]
  apu.spc.psw = spcData[0x2A]
  apu.spc.sp = spcData[0x2B]

  for j in 0..<0x10000:
    apu.spc.ram[j] = spcData[0x100 + j]

  for j in 0..<128:
    apu.dsp.regs[j] = spcData[0x10100 + j]

  apu.spc.stopped = false
  apu.spc.iplEnabled = false

  # Hydrate active voices from current regs (sample dir + nonzero vol/pitch).
  # Mirrors internal startVoice() logic without calling write() / re-KON.
  for v in 0..7:
    let vl = apu.dsp.regs[v * 0x10 + 0]
    let vr = apu.dsp.regs[v * 0x10 + 1]
    let p = (apu.dsp.regs[v * 0x10 + 2].uint16) or
            ((apu.dsp.regs[v * 0x10 + 3].uint16 and 0x3F) shl 8)
    if vl != 0 or vr != 0 or p != 0:
      apu.dsp.forceKeyOnForTest(v)

  # Render N seconds via runSample()
  createDir("bin")
  let totalFrames = int(seconds * float(SampleRate) + 0.5)
  var ours = newSeq[int16](totalFrames * 2)
  for f in 0..<totalFrames:
    let (l, r) = apu.runSample()
    ours[f * 2] = l
    ours[f * 2 + 1] = r

  writeWav("bin/audio_diff_ours.wav", ours)
  echo &"wrote bin/audio_diff_ours.wav ({ours.len div 2} frames)"

  # --- PART B2: invoke reference (build if needed) ---
  let spc2wavBin = "third_party/snes_spc/spc2wav"
  if not fileExists(spc2wavBin):
    echo "spc2wav missing; running build.sh ..."
    let rcBuild = execCmd("bash third_party/snes_spc/build.sh")
    if rcBuild != 0 or not fileExists(spc2wavBin):
      echo "ERROR: could not build spc2wav. Run: cd third_party/snes_spc && bash build.sh"
      quit(1)

  let refPath = "bin/audio_diff_ref.wav"
  let filterArg = if applyFilter: "" else: " --no-filter"
  let refCmd = &"{spc2wavBin} {spcPath} {refPath} {seconds}{filterArg}"
  echo &"ref: {refCmd}"
  let rcRef = execCmd(refCmd)
  if rcRef != 0 or not fileExists(refPath):
    echo &"ERROR: reference render failed (rc={rcRef})"
    quit(1)

  let refs = readWav(refPath)
  echo &"read ref WAV: {refs.len div 2} frames"

  # Align lengths
  let n = min(ours.len, refs.len)
  if n < 100:
    echo "ERROR: too few samples"
    quit(1)
  let o = if ours.len == n: ours else: ours[0..<n]
  let r = if refs.len == n: refs else: refs[0..<n]

  # --- PART B3: diff + report ---
  let skipFrames = int(skipSec * float(SampleRate) + 0.5)
  let skipOff = skipFrames * 2
  let postStart = min(skipOff, o.len)
  let oPost = o[postStart ..< o.len]
  let rPost = r[postStart ..< r.len]
  let postFrames = min(oPost.len, rPost.len) div 2

  if postFrames < 100:
    echo "ERROR: after skip, too few frames to diff"
    quit(1)

  # (a) overall normalized RMS
  let refRmsL = channelRms(rPost, 0)
  let refRmsR = channelRms(rPost, 1)
  let errRmsL = channelRmsError(oPost, rPost, 0)
  let errRmsR = channelRmsError(oPost, rPost, 1)
  let normL = if refRmsL > 1e-9: (errRmsL / refRmsL) * 100.0 else: 0.0
  let normR = if refRmsR > 1e-9: (errRmsR / refRmsR) * 100.0 else: 0.0

  echo "=== PCM DIFF REPORT ==="
  echo &"SPC: {spcPath}"
  echo &"rendered {seconds}s , skip {skipSec}s ({postFrames} frames post-skip)"
  echo &"Overall normalized RMS err L: {normL:.2f}% of ref (refRMS={refRmsL:.1f})"
  echo &"Overall normalized RMS err R: {normR:.2f}% of ref (refRMS={refRmsR:.1f})"

  # (b) per-window error curve, top worst
  echo ""
  echo "Per-window (~50ms) RMS error (top divergences):"
  var winStats: seq[tuple[t: float, eL: float, eR: float]] = @[]
  var w = 0
  while true:
    let f0 = w * WindowFrames
    if f0 >= postFrames: break
    let f1 = min(f0 + WindowFrames, postFrames)
    let nf = f1 - f0
    if nf < 200: break
    let eL = channelRmsError((oPost[f0*2 ..< f1*2]), (rPost[f0*2 ..< f1*2]), 0)
    let eR = channelRmsError((oPost[f0*2 ..< f1*2]), (rPost[f0*2 ..< f1*2]), 1)
    let t = skipSec + (float(f0) / float(SampleRate))
    winStats.add( (t, eL, eR) )
    inc w
    if w > 300: break  # safety

  # find top worst (no fancy sort to keep parser simple)
  let showN = min(5, winStats.len)
  var printed = 0
  var worstT = 0.0
  var worstErr = 0.0
  for ws in winStats:
    let me = max(ws.eL, ws.eR)
    if me > worstErr:
      worstErr = me
      worstT = ws.t
    if printed < showN:
      echo &"  @{ws.t:.2f}s : errL={ws.eL:.1f} errR={ws.eR:.1f}"
      inc printed
  if winStats.len > 0:
    echo &"  (worst at ~{worstT:.2f}s post-skip; {winStats.len} windows total)"

  # (c) dominant freq on a few representative windows (first, ~1/3, ~2/3)
  echo ""
  echo "Dominant freq (simple DFT scan) on representative post-skip windows:"
  # simplified to avoid any parser edge; use explicit windows
  var domRatios: seq[float] = @[]
  let repOffsets = [0, postFrames div 3, (postFrames * 2) div 3]
  for idx in 0..2:
    let rf = repOffsets[idx]
    if rf + 400 >= postFrames: continue
    let nf = min(WindowFrames, postFrames - rf)
    let domOursL = dominantFreq(oPost, rf, nf, 0)
    let domRefL = dominantFreq(rPost, rf, nf, 0)
    let domOursR = dominantFreq(oPost, rf, nf, 1)
    let domRefR = dominantFreq(rPost, rf, nf, 1)
    let tt = skipSec + (float(rf) / float(SampleRate))
    let rL = if domRefL > 10.0: domOursL / domRefL else: 1.0
    let rR = if domRefR > 10.0: domOursR / domRefR else: 1.0
    domRatios.add(rL)
    domRatios.add(rR)
    echo &"  @{tt:.2f}s L: ours={domOursL:.0f} ref={domRefL:.0f} ratio={rL:.3f}   R: ours={domOursR:.0f} ref={domRefR:.0f} ratio={rR:.3f}"
  var sumR = 0.0
  for rrr in domRatios: sumR += rrr
  let avgFreqRatio = if domRatios.len > 0: sumR / float(domRatios.len) else: 1.0
  echo &"  avg freq ratio (ours/ref) ~{avgFreqRatio:.3f}"

  # (d) amplitude envelope (per-window RMS)
  echo ""
  echo "Amplitude envelope (window RMS, first 0.5s post-skip shown):"
  let earlyFrames = min(int(0.5 * float(SampleRate)) div WindowFrames * WindowFrames, postFrames)
  var earlyRatios: seq[float] = @[]
  var ew = 0
  while ew * WindowFrames < earlyFrames + 1 and ew < 12:
    let f0 = ew * WindowFrames
    let nf = min(WindowFrames, postFrames - f0)
    if nf < 200: break
    let roL = windowRms(oPost, f0, nf, 0)
    let rrL = windowRms(rPost, f0, nf, 0)
    let _roR = windowRms(oPost, f0, nf, 1)
    let _rrR = windowRms(rPost, f0, nf, 1)
    let rat = if rrL > 1.0: roL / rrL else: 0.0
    earlyRatios.add(rat)
    let tt = skipSec + (float(f0) / float(SampleRate))
    echo &"  @{tt:.2f}s rmsOursL={roL:7.1f} rmsRefL={rrL:7.1f} ratioL={rat:.2f}"
    inc ew

  var sumEarly = 0.0
  for er in earlyRatios: sumEarly += er
  let earlyAvgRatio = if earlyRatios.len > 0: sumEarly / float(earlyRatios.len) else: 1.0
  echo &"  early (0.5s) avg amp ratio (L) ~{earlyAvgRatio:.2f}"

  # (e) VERDICT
  echo ""
  let maxNorm = max(normL, normR)
  var verdict = "within tolerance"
  if abs(avgFreqRatio - 1.0) > 0.08:
    verdict = "PITCH / VxPITCH resample (dsp.nim pitchCounter/step)"
  elif abs(earlyAvgRatio - 1.0) > 0.25 or (earlyAvgRatio < 0.6 or earlyAvgRatio > 1.6):
    verdict = "ADSR/GAIN envelope (dsp.nim stepEnvelope)"
  elif maxNorm > 40.0:
    verdict = "noise LFSR / NON path (or broadband)"
  elif maxNorm > RmsTolerancePercent:
    verdict = "BRR/interp/echo — inspect"
  else:
    verdict = "within tolerance"

  let status = if maxNorm < RmsTolerancePercent: "PASS (<5%)" else: "DIVERGES"
  echo &"VERDICT: {verdict}  normRMS={maxNorm:.2f}%  {status}"

  # Always exit 0 (report tool)
  echo "done."

when isMainModule:
  main()
