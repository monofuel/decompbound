## Wave-2 song-start dig: compare pack lists, block targets, and post-upload
## SPC PC/FLG/stopped for two songs (default 1 vs 3). Stdout only; no WAV.
## Mirrors sound_explore upload + kick so numbers match the jukebox path.

import
  std/[parseopt, strformat, strutils],
  ../decompbound/apu

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  SampleRate = 32000
  SongTableFile = 0x04F70A
  PackTableFile = 0x04F947
  # TODO: magic bytes from IPL side effect; reverse bootstrap if needed.
  Ipl0500Stub: array[32, uint8] = [
    0x20'u8, 0xCD, 0xCF, 0xBD, 0xE8, 0x00, 0x5D, 0xAF,
    0xC8, 0xE0, 0xD0, 0xFB, 0x3F, 0xA5, 0x16, 0xE8,
    0x55, 0xC4, 0x18, 0xC4, 0x19, 0xE8, 0x00, 0xBC,
    0x3F, 0x2C, 0x0B, 0xA2, 0x48, 0xE8, 0x70, 0x8D
  ]

type
  BlockInfo = object
    len: int
    tgt: int
  PackInfo = object
    idx: int
    fileOff: int
    blocks: seq[BlockInfo]
    wrote0500: bool

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc getSongPackIndices(rom: seq[uint8], songId: int): seq[int] =
  ## Lookup up to 3 pack indices for songId; skip 0xFF slots.
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

proc parsePackageBlocks(rom: seq[uint8], fileOff: int): seq[BlockInfo] =
  ## Walk package blocks without writing RAM.
  result = @[]
  var pos = fileOff
  while pos + 3 < rom.len:
    let len = (rom[pos + 0].int) or (rom[pos + 1].int shl 8)
    let tgt = (rom[pos + 2].int) or (rom[pos + 3].int shl 8)
    pos += 4
    if len == 0:
      break
    result.add(BlockInfo(len: len, tgt: tgt))
    if pos + len > rom.len:
      break
    pos += len

proc loadPackageToRam(ram: var array[0x10000, uint8], rom: seq[uint8], fileOff: int) =
  ## Replicate $C0AB06 package block copy into APU RAM.
  var pos = fileOff
  while pos + 3 < rom.len:
    let len = (rom[pos + 0].int) or (rom[pos + 1].int shl 8)
    let tgt = (rom[pos + 2].int) or (rom[pos + 3].int shl 8)
    pos += 4
    if len == 0:
      break
    if pos + len > rom.len:
      break
    for i in 0..<len:
      let a = tgt + i
      if a >= 0 and a < 0x10000:
        ram[a] = rom[pos + i]
    pos += len

proc describePack(rom: seq[uint8], packIdx: int): PackInfo =
  ## Collect block list and whether pack touches $0500.
  let foff = packFileOffset(rom, packIdx)
  let blocks = parsePackageBlocks(rom, foff)
  var wrote = false
  for b in blocks:
    if b.tgt <= 0x0500 and b.tgt + b.len > 0x0500:
      wrote = true
  PackInfo(idx: packIdx, fileOff: foff, blocks: blocks, wrote0500: wrote)

proc dumpPacks(rom: seq[uint8], packs: seq[int], label: string) =
  ## Print pack list + every block target for a song's upload set.
  echo &"=== {label} packs={packs} ==="
  for p in packs:
    let info = describePack(rom, p)
    echo &"  pack {info.idx} file=0x{info.fileOff:06X} blocks={info.blocks.len} wrote0500={info.wrote0500}"
    for bi, b in info.blocks:
      let endAddr = b.tgt + b.len - 1
      echo &"    [{bi}] len={b.len:5d} tgt=${b.tgt:04X}..${endAddr:04X}"

proc snapState(apu: Apu, tag: string) =
  ## Print SPC PC/SP/stopped + key DSP regs.
  let d = apu.dsp
  echo &"  {tag}: pc=${apu.spc.pc:04X} sp=${apu.spc.sp:02X} stopped={apu.spc.stopped} " &
    &"portsOut=[{apu.portsOut[0]:02X} {apu.portsOut[1]:02X} {apu.portsOut[2]:02X} {apu.portsOut[3]:02X}] " &
    &"mvol=${d.regs[0x0C]:02X}/${d.regs[0x1C]:02X} dir=${d.regs[0x5D]:02X} flg=${d.regs[0x6C]:02X} " &
    &"esa=${d.regs[0x6D]:02X} edl=${d.regs[0x7D]:02X} kon=${d.regs[0x4C]:02X}"

proc runSongPath(rom: seq[uint8], song: int, prependEngine: bool, useStubIfMissing: bool): Apu =
  ## Same upload+kick path as sound_explore; returns live Apu after kick+short play.
  var packs = getSongPackIndices(rom, song)
  let tablePacks = packs
  if prependEngine and 1 notin packs:
    packs = @[1] & packs
  echo &"--- song {song} table={tablePacks} upload={packs} prependEngine={prependEngine} ---"
  dumpPacks(rom, packs, &"song{song}")

  var apuRam: array[0x10000, uint8]
  var last0500Writer = -1
  for p in packs:
    let before = apuRam[0x0500]
    loadPackageToRam(apuRam, rom, packFileOffset(rom, p))
    if apuRam[0x0500] != before or apuRam[0x0500] != 0:
      # Track which pack last changed $0500 region meaningfully.
      let info = describePack(rom, p)
      if info.wrote0500:
        last0500Writer = p
  echo &"  $0500 after packs: first16=" &
    (block:
      var s = ""
      for i in 0..<16:
        s.add(&"{apuRam[0x0500 + i]:02X} ")
      s) &
    &" last0500Writer={last0500Writer}"
  if useStubIfMissing and apuRam[0x0500] == 0:
    for i in 0..<Ipl0500Stub.len:
      apuRam[0x0500 + i] = Ipl0500Stub[i]
    echo "  applied Ipl0500Stub (byte@0500 was 0)"

  let apu = newApu()
  for i in 0..<0x10000:
    apu.spc.ram[i] = apuRam[i]
  apu.spc.pc = 0x0500'u16
  apu.spc.sp = 0xEF'u8
  apu.spc.a = 0
  apu.spc.x = 0
  apu.spc.y = 0
  apu.spc.psw = 0
  snapState(apu, "post-load (before run)")

  for _ in 0..<(SampleRate div 5):
    discard apu.runSample()
  snapState(apu, "after init ~0.2s")

  apu.portsIn[3] = 0x57'u8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  snapState(apu, "after 0x57->P3")

  apu.portsIn[1] = 1'u8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  snapState(apu, "after 0x01->P1")

  apu.portsIn[0] = 0'u8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  snapState(apu, "after 0x00->P0")

  apu.portsIn[0] = (song and 0xFF).uint8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  snapState(apu, "after songN->P0")

  # Short render window for peak / stop state.
  var maxAbs = 0
  var nonzero = 0
  let playN = SampleRate  # 1s
  for si in 0..<playN:
    if si > 0 and (si mod (SampleRate div 2) == 0):
      apu.portsIn[0] = (song and 0xFF).uint8
    let (l, r) = apu.runSample()
    let al = abs(l.int)
    let ar = abs(r.int)
    if al > maxAbs: maxAbs = al
    if ar > maxAbs: maxAbs = ar
    if al > 0 or ar > 0: nonzero += 1
  snapState(apu, "after 1s play")
  echo &"  peakAbs={maxAbs} nonzero={nonzero}/{playN*2}"
  echo &"  ram[0500..050F] live=" &
    (block:
      var s = ""
      for i in 0..<16:
        s.add(&"{apu.spc.ram[0x0500 + i]:02X} ")
      s)
  result = apu

proc main() =
  ## Compare two songs' pack targets and SPC halt state after the jukebox path.
  var
    romPath = DefaultRom
    songA = 1
    songB = 3
    noPrepend = false
    pendingKey = ""

  proc applyOpt(k: string, v: string) =
    case k
    of "rom": romPath = v
    of "a": songA = parseInt(v)
    of "b": songB = parseInt(v)
    of "no-prepend": noPrepend = true
    of "help", "h":
      echo "Usage: nim r src/tools/songstart_dig.nim [--a 1] [--b 3] [--rom path] [--no-prepend]"
      quit(0)
    else: discard

  for kind, key, val in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if pendingKey.len > 0:
        applyOpt(pendingKey, key)
        pendingKey = ""
        continue
      if val.len > 0:
        applyOpt(key, val)
      elif key in ["rom", "a", "b"]:
        pendingKey = key
      else:
        applyOpt(key, "")
    of cmdArgument:
      if pendingKey.len > 0:
        applyOpt(pendingKey, key)
        pendingKey = ""
    else: discard
  if pendingKey.len > 0:
    quit(&"missing value for --{pendingKey}")

  let rom = readRomFile(romPath)
  echo &"ROM {romPath} len={rom.len}"
  echo ""
  echo "==== WITH engine prepend (sound_explore default) ===="
  discard runSongPath(rom, songA, prependEngine = not noPrepend, useStubIfMissing = true)
  echo ""
  discard runSongPath(rom, songB, prependEngine = not noPrepend, useStubIfMissing = true)

  # Extra: song B without prepend, to see if pack set already includes engine-like code.
  if not noPrepend:
    echo ""
    echo "==== song B WITHOUT pack-1 prepend (table packs only) ===="
    discard runSongPath(rom, songB, prependEngine = false, useStubIfMissing = true)

  # Pack 1 alone as baseline engine health.
  echo ""
  echo "==== pack 1 alone (engine smoke) ===="
  var apuRam: array[0x10000, uint8]
  let f1 = packFileOffset(rom, 1)
  dumpPacks(rom, @[1], "pack1-only")
  loadPackageToRam(apuRam, rom, f1)
  let apu = newApu()
  for i in 0..<0x10000:
    apu.spc.ram[i] = apuRam[i]
  apu.spc.pc = 0x0500'u16
  apu.spc.sp = 0xEF'u8
  snapState(apu, "pack1 post-load")
  for _ in 0..<(SampleRate div 5):
    discard apu.runSample()
  snapState(apu, "pack1 after 0.2s")
  apu.portsIn[3] = 0x57'u8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  apu.portsIn[1] = 1'u8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  apu.portsIn[0] = 0'u8
  for _ in 0..<(SampleRate div 200):
    discard apu.runSample()
  apu.portsIn[0] = 1'u8
  var maxAbs = 0
  for si in 0..<SampleRate:
    let (l, r) = apu.runSample()
    let al = abs(l.int)
    let ar = abs(r.int)
    if al > maxAbs: maxAbs = al
    if ar > maxAbs: maxAbs = ar
  snapState(apu, "pack1 + song1 kick 1s")
  echo &"  peakAbs={maxAbs}"

when isMainModule:
  main()
