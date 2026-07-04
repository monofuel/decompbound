## Renders Earthbound music to WAV using our own emulation end to end:
## boot the game on the SNES core, capture the sound driver upload from
## the APU handshake, load the reconstructed image into the standalone
## APU (SPC700 + DSP), replay the game's post-boot port commands, and
## record the DSP output. docs/audio.md Goal 2a: hear Pollyanna.
## Usage: nim r src/tools/render_song.nim <rom> <out.wav> [seconds] [boot-instructions]

import
  std/[os, strformat, strutils],
  ../decompbound/[apu, cpu, snesbus]

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

  var seconds = 30
  var bootInstructions = 3_000_000
  if paramCount() >= 3:
    seconds = parseInt(paramStr(3))
  if paramCount() >= 4:
    bootInstructions = parseInt(paramStr(4))

  # Phase 1: boot the game and capture the driver upload + commands.
  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  for executed in 0..<bootInstructions:
    if (snes.nmitimen and 0x80) != 0 and
       executed mod InstructionsPerFrame == 0 and executed > 0:
      cpu.nmiPending = true
    cpu.step(snes.bus)
    if cpu.stopped:
      break
  echo &"Captured upload: {snes.apuUploadBytes} bytes, entry ${snes.apuEntry:04X}, " &
    &"{snes.apuPostBoot.len} post-boot port writes"
  for (counter, flag, target) in snes.apuJumps:
    echo &"  jump pair: counter={counter:02X} flag={flag:02X} target=${target:04X}"

  # Phase 2: run the driver on the standalone APU.
  let apuUnit = newApu()
  for i in 0..<0x10000:
    apuUnit.spc.ram[i] = snes.apuImage[i]
  apuUnit.spc.pc = if snes.apuEntry != 0: snes.apuEntry else: 0x0500
  apuUnit.spc.sp = 0xEF

  var samples = newSeq[int16]()
  let total = seconds * SampleRate
  var portIndex = 0
  # Pace the game's recorded port writes: a handful per driver tick.
  let writesPerSecond = 200
  let samplesPerWrite = SampleRate div writesPerSecond

  for sampleIndex in 0..<total:
    if portIndex < snes.apuPostBoot.len and
       sampleIndex mod samplesPerWrite == 0:
      let (port, value) = snes.apuPostBoot[portIndex]
      apuUnit.portsIn[(port - 0x2140).int] = value
      portIndex += 1
    let (left, right) = apuUnit.runSample()
    samples.add left
    samples.add right

  writeWav(paramStr(2), samples)

  var nonzero = 0
  for s in samples:
    if s != 0:
      nonzero += 1
  echo &"Wrote {paramStr(2)}: {seconds}s, {nonzero}/{samples.len} nonzero samples"
  echo &"SPC stopped: {apuUnit.spc.stopped}, final PC: ${apuUnit.spc.pc:04X}"
  echo &"DSP register writes: {apuUnit.dsp.writes}"

when isMainModule:
  main()
