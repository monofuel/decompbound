## Jukebox: given a song ID, resolve packs from the song+pack tables,
## upload the package blocks directly into a fresh APU (as $C0AB06 streamer does),
## kick playback via port, and render offline WAV via the emulator APU+DSP.
## Supports headless use: --song N [--seconds S|--frames F] [--out path]
## Output goes to bin/ (gitignored). Never commits audio.
## Per docs/audio.md: song table 0x04F70A (3 pack idx/song), pack table 0x04F947,
## packages [u16 len][u16 tgt][payload]..0, kick exec at $0500, BRR dir $6C00.

import
  std/[parseopt, strformat, strutils],
  ../decompbound/apu

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  SampleRate = 32000
  SongTableFile = 0x04F70A
  PackTableFile = 0x04F947
  # Stub deposited at $0500 by IPL side of the upload protocol (when streamer forces
  # exec target $0500 on len=0). Captured from live APU+IPL during real package upload.
  # TODO: magic bytes from protocol side effect; reverse the small IPL bootstrap if needed.
  Ipl0500Stub: array[32, uint8] = [
    0x20'u8, 0xCD, 0xCF, 0xBD, 0xE8, 0x00, 0x5D, 0xAF,
    0xC8, 0xE0, 0xD0, 0xFB, 0x3F, 0xA5, 0x16, 0xE8,
    0x55, 0xC4, 0x18, 0xC4, 0x19, 0xE8, 0x00, 0xBC,
    0x3F, 0x2C, 0x0B, 0xA2, 0x48, 0xE8, 0x70, 0x8D
  ]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc writeWav(path: string, samples: seq[int16]) =
  ## Write 16-bit stereo 32kHz PCM to WAV file.
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
  put16(20, 1)
  put16(22, 2)
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

proc getSongPackIndices(rom: seq[uint8], songId: int): seq[int] =
  ## Lookup up to 3 pack indices for songId from the verified song table.
  ## 0xFF entries are skipped (unused).
  if songId < 1:
    quit("song id must be >= 1")
  let base = SongTableFile + (songId - 1) * 3
  if base + 2 >= rom.len:
    quit(&"song table overrun for id {songId}")
  result = @[]
  for i in 0..2:
    let p = rom[base + i].int
    if p != 0xFF:
      result.add(p)

proc packFileOffset(rom: seq[uint8], packIdx: int): int =
  ## Pack table entry -> far ptr -> file offset (HiROM mapping).
  let base = PackTableFile + packIdx * 3
  if base + 2 >= rom.len:
    quit(&"pack table overrun for idx {packIdx}")
  let bank = rom[base + 0]
  let lo = rom[base + 1]
  let hi = rom[base + 2]
  result = ((bank and 0x3F).int shl 16) or ((hi.int shl 8) or lo.int)

proc loadPackageToRam(ram: var array[0x10000, uint8], rom: seq[uint8], fileOff: int) =
  ## Replicate $C0AB06 package exactly: walk blocks, copy payloads to tgt RAM.
  var pos = fileOff
  while pos + 3 < rom.len:
    let len = (rom[pos + 0].int) or (rom[pos + 1].int shl 8)
    let tgt = (rom[pos + 2].int) or (rom[pos + 3].int shl 8)
    pos += 4
    if len == 0: break
    if pos + len > rom.len: break
    for i in 0..<len:
      let a = tgt + i
      if a >= 0 and a < 0x10000: ram[a] = rom[pos + i]
    pos += len

proc main() =
  ## Parse CLI, resolve song packs, build fresh APU RAM image from packages + IPL stub,
  ## boot driver at 0500, kick with song id on port, render WAV.
  var
    romPath = DefaultRom
    song = 1
    seconds = 5
    frames = -1
    outPath = ""
    help = false
    pendingKey = ""

  proc applyOpt(k: string, v: string) =
    case k
    of "rom": romPath = v
    of "song": song = parseInt(v)
    of "seconds": seconds = parseInt(v)
    of "frames": frames = parseInt(v)
    of "out": outPath = v
    of "help": help = true
    else: discard

  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if pendingKey.len > 0:
        applyOpt(pendingKey, key)  # key was actually the val for prior
        pendingKey = ""
        continue
      let k = if key.len > 0: key else: ""
      if val.len > 0:
        applyOpt(k, val)
      else:
        if k in ["song", "seconds", "frames", "rom", "out"]:
          pendingKey = k
        elif k in ["help", "h"]:
          help = true
    of cmdArgument:
      if pendingKey.len > 0:
        applyOpt(pendingKey, key)
        pendingKey = ""
      # ignore bare args
    else: discard
  if pendingKey.len > 0:
    echo &"missing value for --{pendingKey}"
    help = true

  if help or song < 1:
    echo "Usage: nim r src/tools/sound_explore.nim --song N [--rom path] [--seconds S | --frames F] [--out bin/xx.wav]"
    echo "  Renders EarthBound song via direct pack upload to standalone APU+DSP."
    quit(0)

  if outPath.len == 0:
    outPath = &"bin/jukebox_song{song:03d}.wav"

  let rom = readRomFile(romPath)
  let packs = getSongPackIndices(rom, song)
  echo &"song {song} -> packs {packs}"

  var apuRam: array[0x10000, uint8]
  for i in 0..<Ipl0500Stub.len:
    apuRam[0x0500 + i] = Ipl0500Stub[i]
  for p in packs:
    let foff = packFileOffset(rom, p)
    echo &"  loading pack {p} from file 0x{foff:06X}"
    loadPackageToRam(apuRam, rom, foff)

  let apu = newApu()
  for i in 0..<0x10000:
    apu.spc.ram[i] = apuRam[i]
  apu.spc.pc = 0x0500'u16
  apu.spc.sp = 0xEF'u8
  apu.spc.a = 0
  apu.spc.x = 0
  apu.spc.y = 0
  apu.spc.psw = 0

  apu.portsIn[0] = (song and 0xFF).uint8
  for i in 1..3: apu.portsIn[i] = 0

  let total = if frames > 0: frames else: seconds * SampleRate
  var samples = newSeq[int16]()
  var nonzero = 0
  var maxAbs = 0

  # Pace pokes lightly; avoid disturbing resident driver after start.
  # Initial kick is main; occasional 0 may ack polls in some drivers.
  for si in 0..<total:
    if si == SampleRate div 2:
      apu.portsIn[0] = 0'u8
    let (l, r) = apu.runSample()
    samples.add(l)
    samples.add(r)
    let al = abs(l.int); let ar = abs(r.int)
    if al > 0 or ar > 0: nonzero += 1
    if al > maxAbs: maxAbs = al
    if ar > maxAbs: maxAbs = ar

  writeWav(outPath, samples)

  let secs = samples.len.float / 2.0 / float(SampleRate)
  echo &"wrote {outPath}: {secs:.2f}s, {nonzero}/{samples.len} nonzero samples, peakAbs={maxAbs}"
  echo &"final spc pc=${apu.spc.pc:04X} stopped={apu.spc.stopped}"
  # Quick sanity on DSP (master vol etc may be set by driver).
  let d = apu.dsp
  echo &"dsp mvolL/R=${d.regs[0x0C]:02X} ${d.regs[0x1C]:02X} flg=${d.regs[0x6C]:02X}"

when isMainModule:
  main()
