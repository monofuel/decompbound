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
  # No personal/hardcoded path. Default is synthesized low-pitch tone (portable).
  DefaultSeconds = 2.0
  DefaultSkip = 0.1
  SampleRate = 32000
  RmsTolerancePercent = 5.0
  WindowFrames = 1600  # ~50 ms at 32 kHz
  NumLogBins = 20

  # For --song mode: replicate sound_explore upload path (song table 0x04F70A,
  # pack table 0x04F947, engine pack 1 prepended, $0500 kick, port seq).
  SongTableFile = 0x04F70A
  PackTableFile = 0x04F947
  DefaultRom = "bin/Earthbound (U) [!].smc"
  # Stub from sound_explore (IPL side effect at $0500 for len=0 target).
  Ipl0500Stub: array[32, uint8] = [
    0x20'u8, 0xCD, 0xCF, 0xBD, 0xE8, 0x00, 0x5D, 0xAF,
    0xC8, 0xE0, 0xD0, 0xFB, 0x3F, 0xA5, 0x16, 0xE8,
    0x55, 0xC4, 0x18, 0xC4, 0x19, 0xE8, 0x00, 0xBC,
    0x3F, 0x2C, 0x0B, 0xA2, 0x48, 0xE8, 0x70, 0x8D
  ]

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

proc synthesizeToneSpc(): string =
  ## Generate a portable, self-contained minimal .spc that plays a constant
  ## LOW-pitch tone through a single voice (BRR loop + low VxPITCH + direct GAIN).
  ## Written to bin/test_tone_low.spc (gitignored). Used as default when no --spc.
  ## Both our DSP (via APU) and snes_spc ref will render from identical snapshot.
  ## This exercises Gaussian interp + pitch counter heavily (low pitch = many
  ## interp samples per BRR input sample).
  ##
  ## The .spc contains a tiny SPC700 program at $0600 (outside magic 0500 hook range)
  ## that pokes the DSP regs (dir, sample, vol, low pitch ~0x0200, srcn, gain/direct,
  ## flg no-echo, KON voice0) then idles with periodic re-KON. PC set to program entry
  ## so snes_spc's real SPC700 executes the setup on load/play. DSP regs area also
  ## pre-populated for immediate state on both sides. Header uses correct spc_file_t
  ## layout (sig 35b + has/ver + pc at 0x25 etc) so load_spc succeeds with valid CPU
  ## state. All other voices/FIR/echo zeroed to keep tone clean (no saturation).
  createDir("bin")
  const SpcSize = 0x10200
  var spcData = newSeq[uint8](SpcSize)

  # Correct SPC file header (matches snes_spc spc_file_t + init_header).
  let sig = "SNES-SPC700 Sound File Data v0.30\x1A\x1A"
  for k in 0..<sig.len:
    spcData[k] = sig[k].uint8
  spcData[0x23] = 26'u8   # has_id666 (none)
  spcData[0x24] = 30'u8   # version
  const ProgramEntry = 0x0600'u16  # safe addr: outside runSample 0500-05FF kick hook
  spcData[0x25] = (ProgramEntry and 0xFF).uint8  # pcl
  spcData[0x26] = ((ProgramEntry shr 8) and 0xFF).uint8  # pch
  spcData[0x27] = 0'u8    # a
  spcData[0x28] = 0'u8    # x
  spcData[0x29] = 0'u8    # y
  spcData[0x2A] = 0'u8    # psw
  spcData[0x2B] = 0xEF'u8 # sp
  # text[212] at 0x2C remains 0

  # Sample dir at $0200: srcn0 start $0300, loop $0300
  spcData[0x100 + 0x0200] = 0x00
  spcData[0x100 + 0x0201] = 0x03
  spcData[0x100 + 0x0202] = 0x00
  spcData[0x100 + 0x0203] = 0x03

  # Minimal 1-block looped BRR at $0300 (range=0, filter=0, end+loop flag).
  # Decodes to small signed steps forming a low-freq triangle-ish wave.
  # At pitch 0x0200 (1/8 rate) -> ~250Hz fundamental (low pitch for interp stress).
  let brr = [0x03'u8, 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE]
  for i, b in brr:
    spcData[0x100 + 0x0300 + i] = b

  # Tiny SPC700 program at $0600: pokes via 8F xx F2 / 8F yy F3, KON, then clean self-loop idle.
  # snes_spc executes from PC=entry (runs the setup pokes live to configure DSP/KON).
  # Our side uses snapshot DSP regs + force (SPC steps will also hit the KON write via hook).
  # Idle is pure "bra -2" (no further writes after setup, no opcode misalignment risk).
  let setup = [
    # mvolL $0C=7F
    0x8F'u8, 0x0C, 0xF2, 0x8F'u8, 0x7F, 0xF3,
    # mvolR $1C=7F
    0x8F'u8, 0x1C, 0xF2, 0x8F'u8, 0x7F, 0xF3,
    # dir $5D=02
    0x8F'u8, 0x5D, 0xF2, 0x8F'u8, 0x02, 0xF3,
    # v0 volL $00=7F
    0x8F'u8, 0x00, 0xF2, 0x8F'u8, 0x7F, 0xF3,
    # v0 volR $01=7F
    0x8F'u8, 0x01, 0xF2, 0x8F'u8, 0x7F, 0xF3,
    # v0 pitchL $02=00 , pitchH $03=02  => 0x0200 (LOW pitch, heavy Gaussian)
    0x8F'u8, 0x02, 0xF2, 0x8F'u8, 0x00, 0xF3,
    0x8F'u8, 0x03, 0xF2, 0x8F'u8, 0x02, 0xF3,
    # srcn $04=00
    0x8F'u8, 0x04, 0xF2, 0x8F'u8, 0x00, 0xF3,
    # adsr1 $05=00 (gain mode), adsr2 $06=00
    0x8F'u8, 0x05, 0xF2, 0x8F'u8, 0x00, 0xF3,
    0x8F'u8, 0x06, 0xF2, 0x8F'u8, 0x00, 0xF3,
    # gain $07=7F direct full sustain
    0x8F'u8, 0x07, 0xF2, 0x8F'u8, 0x7F, 0xF3,
    # flg $6C=20 (echo disabled, no reset/mute)
    0x8F'u8, 0x6C, 0xF2, 0x8F'u8, 0x20, 0xF3,
    # KON $4C=01 voice0  -- last setup write
    0x8F'u8, 0x4C, 0xF2, 0x8F'u8, 0x01, 0xF3,
    # clean idle: bra *-2 (self). Once reached, no side effects, stays here.
    0x2F'u8, 0xFE
  ]
  for i, b in setup:
    spcData[0x100 + 0x0600 + i] = b

  # DSP regs snapshot at 0x10100 (pre-set to match program pokes; snes_spc load
  # will also see new_kon from kon reg and program will re-apply on run).
  # Zero everything else (FIR, echo, other voices) to prevent saturation/bleed.
  spcData[0x10100 + 0x00] = 0x7F  # v0 volL
  spcData[0x10100 + 0x01] = 0x7F  # v0 volR
  spcData[0x10100 + 0x02] = 0x00  # v0 pitchL
  spcData[0x10100 + 0x03] = 0x02  # v0 pitchH -> 0x0200
  spcData[0x10100 + 0x04] = 0x00  # v0 srcn
  spcData[0x10100 + 0x05] = 0x00  # v0 adsr1 (gain)
  spcData[0x10100 + 0x06] = 0x00  # v0 adsr2
  spcData[0x10100 + 0x07] = 0x7F  # v0 gain (direct)
  spcData[0x10100 + 0x0C] = 0x7F  # mvolL
  spcData[0x10100 + 0x1C] = 0x7F  # mvolR
  spcData[0x10100 + 0x4C] = 0x01  # kon (voice0)
  spcData[0x10100 + 0x5D] = 0x02  # dir
  spcData[0x10100 + 0x6C] = 0x20  # flg (echo off)
  # zero echo vols, esa, edl, fir coefs (0x0F slots), koff, pmon, non, eon, other voices
  spcData[0x10100 + 0x2C] = 0
  spcData[0x10100 + 0x3C] = 0
  spcData[0x10100 + 0x4D] = 0
  spcData[0x10100 + 0x2D] = 0
  spcData[0x10100 + 0x3D] = 0
  spcData[0x10100 + 0x6D] = 0
  spcData[0x10100 + 0x7D] = 0
  for t in 0..7:
    spcData[0x10100 + t * 0x10 + 0x0F] = 0'u8
  for v in 1..7:
    spcData[0x10100 + v * 0x10 + 0] = 0
    spcData[0x10100 + v * 0x10 + 1] = 0

  let tonePath = "bin/test_tone_low.spc"
  var outStr = newString(SpcSize)
  for i, b in spcData:
    outStr[i] = b.char
  writeFile(tonePath, outStr)
  echo &"synthesized portable low-pitch tone SPC: {tonePath} (entry=0x0600, pitch=0x0200, direct GAIN, kon=01)"
  tonePath

proc readRomFileForSong(filepath: string): seq[uint8] =
  ## Read ROM for pack extraction; strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc getSongPackIndices(rom: seq[uint8], songId: int): seq[int] =
  ## Lookup up to 3 pack indices for songId from song table.
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
  ## Pack table entry -> far ptr -> file offset (HiROM).
  let base = PackTableFile + packIdx * 3
  if base + 2 >= rom.len:
    quit(&"pack table overrun for idx {packIdx}")
  let bank = rom[base + 0]
  let lo = rom[base + 1]
  let hi = rom[base + 2]
  result = ((bank and 0x3F).int shl 16) or ((hi.int shl 8) or lo.int)

proc loadPackageToRam(ram: var array[0x10000, uint8], rom: seq[uint8], fileOff: int) =
  ## Replicate $C0AB06 package block copy: [u16 len][u16 tgt][payload] until len=0.
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

proc snapshotApuToSpc(apu: Apu, songId: int): string =
  ## Build a valid .spc file capturing current APU RAM + SPC CPU state + DSP regs.
  ## For song snapshots: build a setup program that re-applies the captured DSP voice
  ## config (vol/pitch/srcn/gain + re-KON active) so both our DSP and snes_spc
  ## render the high-pitch element voices from identical snapshot state.
  createDir("bin")
  const SpcSize = 0x10200
  var spcData = newSeq[uint8](SpcSize)

  let sig = "SNES-SPC700 Sound File Data v0.30\x1A\x1A"
  for k in 0..<sig.len:
    spcData[k] = sig[k].uint8
  spcData[0x23] = 26'u8
  spcData[0x24] = 30'u8

  # For song: use a setup poke program (re-KON captured voices). For tone keep live pc.
  let useSetup = songId > 0
  let ProgramEntry: uint16 = if useSetup: 0x0F00'u16 else: apu.spc.pc
  spcData[0x25] = (ProgramEntry and 0xFF).uint8
  spcData[0x26] = ((ProgramEntry shr 8) and 0xFF).uint8
  spcData[0x27] = 0'u8
  spcData[0x28] = 0'u8
  spcData[0x29] = 0'u8
  spcData[0x2A] = 0'u8
  spcData[0x2B] = 0xEF'u8

  for j in 0..<0x10000:
    spcData[0x100 + j] = apu.spc.ram[j]
  for j in 0..<128:
    spcData[0x10100 + j] = apu.dsp.regs[j]

  if useSetup:
    # If driver left dir at 00 but table at $6C00, force $5D=6C in snapshot DSP for
    # the .spc render to point voices at the BRR dir/samples (helps resume audio).
    if spcData[0x10100 + 0x5D] == 0:
      spcData[0x10100 + 0x5D] = 0x6C'u8
    # Build SPC700 poke program at ProgramEntry: set mvol/flg/dir, per-voice params for
    # active voices, re-KON them, then clean idle (bra *-2). Matches tone style.
    var setup: seq[uint8] = @[]
    # mvol L/R
    setup.add([0x8F'u8, 0x0C, 0xF2, 0x8F'u8, apu.dsp.regs[0x0C], 0xF3])
    setup.add([0x8F'u8, 0x1C, 0xF2, 0x8F'u8, apu.dsp.regs[0x1C], 0xF3])
    # dir
    setup.add([0x8F'u8, 0x5D, 0xF2, 0x8F'u8, apu.dsp.regs[0x5D], 0xF3])
    # flg (preserve but force no reset/mute if possible)
    var flg = apu.dsp.regs[0x6C]
    if (flg and 0x80) != 0: flg = flg and 0x7F  # avoid soft reset if set
    setup.add([0x8F'u8, 0x6C, 0xF2, 0x8F'u8, flg, 0xF3])
    # per voice: if has vol or pitch, poke its regs + collect kon mask
    var konMask: uint8 = 0
    for v in 0..7:
      let base = v * 0x10
      let vl = apu.dsp.regs[base + 0]
      let vr = apu.dsp.regs[base + 1]
      let pl = apu.dsp.regs[base + 2]
      let ph = apu.dsp.regs[base + 3]
      let p = (pl.uint16) or ((ph.uint16 and 0x3F) shl 8)
      if vl != 0 or vr != 0 or p != 0:
        konMask = konMask or (1'u8 shl v)
        # vol L/R
        setup.add([0x8F'u8, (base + 0).uint8, 0xF2, 0x8F'u8, vl, 0xF3])
        setup.add([0x8F'u8, (base + 1).uint8, 0xF2, 0x8F'u8, vr, 0xF3])
        # pitch L/H
        setup.add([0x8F'u8, (base + 2).uint8, 0xF2, 0x8F'u8, pl, 0xF3])
        setup.add([0x8F'u8, (base + 3).uint8, 0xF2, 0x8F'u8, ph, 0xF3])
        # srcn, adsr1, adsr2, gain
        setup.add([0x8F'u8, (base + 4).uint8, 0xF2, 0x8F'u8, apu.dsp.regs[base+4], 0xF3])
        setup.add([0x8F'u8, (base + 5).uint8, 0xF2, 0x8F'u8, apu.dsp.regs[base+5], 0xF3])
        setup.add([0x8F'u8, (base + 6).uint8, 0xF2, 0x8F'u8, apu.dsp.regs[base+6], 0xF3])
        setup.add([0x8F'u8, (base + 7).uint8, 0xF2, 0x8F'u8, apu.dsp.regs[base+7], 0xF3])
    # KON the active mask
    setup.add([0x8F'u8, 0x4C, 0xF2, 0x8F'u8, konMask, 0xF3])
    # idle bra *-2
    setup.add([0x2F'u8, 0xFE])
    # write setup at ProgramEntry in RAM area of spc
    for ii, b in setup:
      if 0x100 + ProgramEntry.int + ii < SpcSize:
        spcData[0x100 + ProgramEntry.int + ii] = b
    # also ensure DSP snapshot area has the captured (already done)
    # and set initial KON in DSP area for our hydrate path
    spcData[0x10100 + 0x4C] = konMask

  let path = if songId > 0: &"bin/song{songId:03d}_tessie_snapshot.spc" else: "bin/live_snapshot.spc"
  var outStr = newString(SpcSize)
  for i, b in spcData:
    outStr[i] = b.char
  writeFile(path, outStr)
  let pcLogged = if useSetup: ProgramEntry else: apu.spc.pc
  echo &"snapped APU state after song kick+play: {path} (pc=${pcLogged:04X})"
  path

proc main() =
  ## Parse args, load .spc into our APU (direct regs, hydrate voices), render ours,
  ## shell to spc2wav --no-filter (or with filter), read ref, diff + report.
  ## Supports --song N to play real EB song via upload path (sound_explore logic),
  ## snapshot live APU to .spc, then diff that against snes_spc ref (for real high-pitch
  ## element like Tessie wind).
  var spcPath = ""
  var seconds = DefaultSeconds
  var skipSec = DefaultSkip
  var applyFilter = false
  var song = 0
  var romPath = DefaultRom

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
    elif a == "--song" and i < paramCount():
      inc i
      song = parseInt(paramStr(i))
    elif a.startsWith("--song="):
      song = parseInt(a[7 .. ^1])
    elif a == "--rom" and i < paramCount():
      inc i
      romPath = paramStr(i)
    elif a.startsWith("--rom="):
      romPath = a[6 .. ^1]
    elif a == "--help" or a == "-h":
      echo "Usage: nim r src/tools/audio_diff.nim [--spc <path.spc>] [--song N] [--seconds N] [--skip 0.1] [--filter] [--rom path]"
      echo "  --song N : play real song via pack upload (like sound_explore), snapshot APU to .spc, diff it"
      echo "  --filter : let ref use SPC_Filter (default: raw --no-filter for DSP-vs-DSP)"
      echo "  Default (no --spc/--song): synthesize portable low-pitch test tone SPC in bin/"
      quit(0)
    else:
      if not a.startsWith("--") and spcPath.len == 0:
        spcPath = a
    inc i

  if spcPath.len == 0:
    if song > 0:
      # (a) .spc-snapshot route using sound_explore upload path exactly.
      # Play target song (e.g. Tessie sighting), advance into sustained element,
      # snapshot full APU (RAM + SPC regs + DSP regs) to valid .spc.
      echo &"song mode: uploading song {song} via pack tables and kicking..."
      let rom = readRomFileForSong(romPath)
      var packs = getSongPackIndices(rom, song)
      if 1 notin packs:
        packs = @[1] & packs
      echo &"song {song} -> packs {packs}"
      var apuRam: array[0x10000, uint8]
      for p in packs:
        let foff = packFileOffset(rom, p)
        echo &"  loading pack {p} from file 0x{foff:06X}"
        loadPackageToRam(apuRam, rom, foff)
      if apuRam[0x0500] == 0:
        for ii in 0..<Ipl0500Stub.len:
          apuRam[0x0500 + ii] = Ipl0500Stub[ii]
      let apuLive = newApu()
      for ii in 0..<0x10000:
        apuLive.spc.ram[ii] = apuRam[ii]
      apuLive.spc.pc = 0x0500'u16
      apuLive.spc.sp = 0xEF'u8
      apuLive.spc.a = 0
      apuLive.spc.x = 0
      apuLive.spc.y = 0
      apuLive.spc.psw = 0
      for _ in 0 ..< (SampleRate div 5):
        discard apuLive.runSample()
      # Kick protocol (from sound_explore + C4FBBD tail):
      apuLive.portsIn[3] = 0x57'u8
      for _ in 0 ..< (SampleRate div 200):
        discard apuLive.runSample()
      apuLive.portsIn[1] = 1'u8
      for _ in 0 ..< (SampleRate div 200):
        discard apuLive.runSample()
      apuLive.portsIn[0] = 0'u8
      for _ in 0 ..< (SampleRate div 200):
        discard apuLive.runSample()
      apuLive.portsIn[0] = (song and 0xFF).uint8
      # Check dir right after kick (should become 0x6C once driver inits samples).
      echo &"post-kick before advance: dir=${apuLive.dsp.regs[0x5D]:02X} mvol=${apuLive.dsp.regs[0x0C]:02X} flg=${apuLive.dsp.regs[0x6C]:02X}"
      # Advance fixed time post-kick to reach sustained part of song (high wind element).
      # Re-kick song periodically. Snapshot whatever state the driver is in (RAM/DSP at that time).
      let playFrames = int(0.9 * float(SampleRate) + 0.5)
      for fi in 0..<playFrames:
        if (fi mod (SampleRate div 2)) == 0:
          apuLive.portsIn[0] = (song and 0xFF).uint8
        discard apuLive.runSample()
      echo &"advanced {playFrames} frames into song for snapshot; dir=${apuLive.dsp.regs[0x5D]:02X} mvolL=${apuLive.dsp.regs[0x0C]:02X}"
      # Snapshot the live state (driver running, voices+regs+RAM).
      spcPath = snapshotApuToSpc(apuLive, song)
    else:
      spcPath = synthesizeToneSpc()
  if not fileExists(spcPath):
    echo &"ERROR: SPC not found: {spcPath}"
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

  # Sanitize only for synthetic tone snapshots (keep full live state for real-song
  # snapshots so echo, multi-voice, flg, and active high-pitch voices are preserved).
  let isTone = spcPath.contains("test_tone") or spcPath.contains("tone")
  if isTone:
    apu.dsp.regs[0x2C] = 0
    apu.dsp.regs[0x3C] = 0
    apu.dsp.regs[0x6D] = 0
    apu.dsp.regs[0x7D] = 0
    for t in 0..7: apu.dsp.regs[t * 0x10 + 0x0F] = 0'u8
    for v in 1..7:
      apu.dsp.regs[v * 0x10 + 0] = 0
      apu.dsp.regs[v * 0x10 + 1] = 0

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
  # Debug the tone voice state right after force (for synth default)
  let v0pitch = (apu.dsp.regs[2].uint16) or ((apu.dsp.regs[3].uint16 and 0x3F) shl 8)
  let v0srcn = apu.dsp.regs[4]
  let v0gain = apu.dsp.regs[7]
  let v0adsr1 = apu.dsp.regs[5]
  let dir = apu.dsp.regs[0x5D]
  let entry0 = (dir.uint16 * 0x100) + (v0srcn.uint16 * 4)
  let brr0 = (apu.spc.ram[entry0].uint16) or (apu.spc.ram[entry0+1].uint16 shl 8)
  echo &"voice0: pitch=0x{v0pitch:04X} srcn={v0srcn} gain=0x{v0gain:02X} adsr1=0x{v0adsr1:02X} dirPg=0x{dir:02X} brr@=0x{brr0:04X} hdr=0x{apu.spc.ram[brr0]:02X}"

  discard apu.runSample()
  # Warmup: advance SPC (executes pokes from PC) + DSP mixes for several frames so
  # pitch/vol/KON writes complete and low-pitch counter ramps (needs ~8+ frames for
  # first 0x1000 cross + decode). Post-skip render then sees stable tone on both sides.
  # For song snapshots use longer warmup to let setup pokes + envelopes settle.
  let warmupN = if spcPath.contains("song") and spcPath.contains("snapshot"): 64 else: 32
  for _ in 0..<warmupN:
    discard apu.runSample()

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
    discard windowRms(oPost, f0, nf, 1)
    discard windowRms(rPost, f0, nf, 1)
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
