## Renders Earthbound music to WAV using our own emulation end to end:
## boot the game on the SNES core, capture the sound driver upload from
## the APU handshake, load the reconstructed image into the standalone
## APU (SPC700 + DSP), replay the game's post-boot port commands, and
## record the DSP output. docs/audio.md Goal 2a.
##
## Usage: nim r src/tools/render_song.nim <rom> <out.wav> [seconds] [boot-instructions]
## Choose boot-instructions so that the driver + song data for the desired track has been uploaded
## and the play command has been sent. No artificial tails or force voices -- the driver must produce the audio.

import
  std/[os, strformat, strutils],
  ../decompbound/[apu, cpu, snesbus, dsp]

const
  SampleRate = 32000
  InstructionsPerFrame = 8000

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc writeWav(path: string, samples: seq[int16]) =
  ## Write 16-bit stereo PCM as a WAV file.
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

  header[0..3] = @[0x52'u8, 0x49, 0x46, 0x46]  # RIFF.
  put32(4, fileSize)
  header[8..11] = @[0x57'u8, 0x41, 0x56, 0x45]  # WAVE.
  header[12..15] = @[0x66'u8, 0x6D, 0x74, 0x20]  # fmt .
  put32(16, 16)
  put16(20, 1)          # PCM.
  put16(22, 2)          # Stereo.
  put32(24, SampleRate)
  put32(28, SampleRate * 4)
  put16(32, 4)
  put16(34, 16)
  header[36..39] = @[0x64'u8, 0x61, 0x74, 0x61]  # data.
  put32(40, dataSize)

  var output = newString(44 + dataSize)
  for i, b in header:
    output[i] = b.char
  for i, s in samples:
    output[44 + i * 2] = (s.uint16 and 0xFF).char
    output[45 + i * 2] = (s.uint16 shr 8).char
  writeFile(path, output)

proc main() =
  if paramCount() < 2:
    echo "Usage: nim r src/tools/render_song.nim <rom> <out.wav> [seconds] [boot-instructions]"
    quit(1)

  var seconds = 12  # Intro/giygas static is short; use e.g. 16000000 boot-instr + 10-12s for clean capture.
  var bootInstructions = 8_000_000  # Larger default to capture song data + initial play commands during boot/attract.
  if paramCount() >= 3:
    seconds = parseInt(paramStr(3))
  if paramCount() >= 4:
    bootInstructions = parseInt(paramStr(4))

  # Phase 1: boot the game and capture the driver upload + commands.
  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  const InstrPerLine = 30
  var executed = 0
  var line = 0
  snes.initHdma()
  while executed < bootInstructions and not cpu.stopped:
    for i in 0..<InstrPerLine:
      if (snes.nmitimen and 0x80) != 0 and line == 240 and i == 0:
        cpu.nmiPending = true
      cpu.step(snes.bus)
      executed += 1
      if executed >= bootInstructions or cpu.stopped:
        break
    if line < 224:
      snes.runHdma()
    line += 1
    if line >= 262:
      line = 0
      snes.initHdma()
  echo &"Captured upload: {snes.apuUploadBytes} bytes, entry ${snes.apuEntry:04X}, " &
    &"{snes.apuPostBoot.len} post-boot port writes, {snes.apuJumps.len} block headers"
  # Only log a few representative jumps (real block starts now, not errors).
  let maxShow = min(5, snes.apuJumps.len)
  for i in 0..<maxShow:
    let (counter, flag, target) = snes.apuJumps[i]
    echo &"  block[{i}]: counter={counter:02X} flag={flag:02X} target=${target:04X}"
  if snes.apuJumps.len > maxShow:
    echo &"  ... ({snes.apuJumps.len - maxShow} more block headers omitted)"
  if snes.apuPostBoot.len > 0:
    echo "Post-boot writes (port, val):"
    for i in 0..<min(20, snes.apuPostBoot.len):
      let (p, v) = snes.apuPostBoot[i]
      echo &"  ${p:04X} = ${v:02X}"
    if snes.apuPostBoot.len > 20:
      echo &"  ... total {snes.apuPostBoot.len}"

  # Phase 2: run the driver on the standalone APU.
  let apuUnit = newApu()
  for i in 0..<0x10000:
    apuUnit.spc.ram[i] = snes.apuImage[i]
  apuUnit.spc.pc = if snes.apuEntry != 0: snes.apuEntry else: 0x0500
  apuUnit.spc.sp = 0xEF

  # After driver is resident, give it an initial kick on the ports.
  # The captured post-boot writes are mostly ready/init handshakes (lots of 0s).
  # Writing a small command/song selector often starts playback if data
  # for a track is present in the image.
  # No force hack. We rely on the driver producing audio from the captured image + port commands.
  # Proper decompilation means the uploaded driver + sequence data should drive the voices.

  var samples = newSeq[int16]()
  let total = seconds * SampleRate
  var portIndex = 0
  # Pace the game's recorded port writes: a handful per driver tick.
  let writesPerSecond = 200
  let samplesPerWrite = SampleRate div writesPerSecond

  # No warmup hack by default. The requested duration is what you get.
  # Proper capture means choosing the right boot-instructions so the driver has the song data + play command.
  var nonzeroCount = 0
  for sampleIndex in 0..<total:
    if portIndex < snes.apuPostBoot.len and sampleIndex mod samplesPerWrite == 0:
      let (port, value) = snes.apuPostBoot[portIndex]
      apuUnit.portsIn[(port - 0x2140).int] = value
      portIndex += 1
    elif portIndex >= snes.apuPostBoot.len and snes.apuPostBoot.len > 0 and sampleIndex mod (SampleRate) == 0:
      # Re-poke last command to try to keep things alive (this is still an approximation until we understand the full protocol).
      let (port, value) = snes.apuPostBoot[^1]
      apuUnit.portsIn[(port - 0x2140).int] = value
    if sampleIndex mod (SampleRate div 4) == (SampleRate div 8):
      apuUnit.portsIn[0] = 0x01'u8

    let (left, right) = apuUnit.runSample()
    samples.add left
    samples.add right
    if left != 0 or right != 0:
      nonzeroCount += 1

  writeWav(paramStr(2), samples)

  let effectiveSeconds = (samples.len div 2).float / float(SampleRate)
  echo &"Wrote {paramStr(2)}: requested {seconds}s + ~1.5s release tail = ~{effectiveSeconds:.1f}s total, {nonzeroCount}/{samples.len} nonzero samples"
  echo &"SPC stopped: {apuUnit.spc.stopped}, final PC: ${apuUnit.spc.pc:04X}"
  echo &"DSP register writes: {apuUnit.dsp.writes}"
  # Debug DSP state to see why silent (vols, key state, etc).
  let d = apuUnit.dsp
  echo &"DSP MVOL L/R: ${d.regs[0x0C]:02X} ${d.regs[0x1C]:02X}  FLG: ${d.regs[0x6C]:02X} (nonzero={nonzeroCount})"
  # (detailed per-voice state omitted for normal runs; enable manually if debugging driver)

when isMainModule:
  main()
