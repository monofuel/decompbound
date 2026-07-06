## Save/load full emulator state snapshots for the play tool. Uses only
## existing public fields on SnesBus, Cpu and APU (no edits to core files).
## Binary blobs written to bin/states/slotN.state (gitignored).

import
  std/[os, streams, strformat],
  ./[apu, cpu, snesbus]

const
  StateMagic = "DBST"  ## TODO: placeholder magic bytes for decompbound state files.
                       ## Will be refined with proper RE-derived format once needed.
  StateVersion = 1'u32
  WramBase = 0x7E0000
  WramSize = 0x20000

proc writeU8(s: Stream, v: uint8) =
  ## Write single byte to stream.
  s.write(v)

proc writeU16le(s: Stream, v: uint16) =
  ## Write 16-bit value little-endian.
  writeU8(s, (v and 0xFF).uint8)
  writeU8(s, ((v shr 8) and 0xFF).uint8)

proc writeU32le(s: Stream, v: uint32) =
  ## Write 32-bit value little-endian.
  writeU8(s, (v and 0xFF).uint8)
  writeU8(s, ((v shr 8) and 0xFF).uint8)
  writeU8(s, ((v shr 16) and 0xFF).uint8)
  writeU8(s, ((v shr 24) and 0xFF).uint8)

proc writeI32le(s: Stream, v: int32) =
  ## Write signed 32-bit little-endian.
  writeU32le(s, cast[uint32](v))

proc writeI64le(s: Stream, v: int64) =
  ## Write signed 64-bit little-endian.
  let u = cast[uint64](v)
  writeU32le(s, (u and 0xFFFFFFFF'u64).uint32)
  writeU32le(s, ((u shr 32) and 0xFFFFFFFF'u64).uint32)

proc readU8(s: Stream): uint8 =
  ## Read single byte.
  var b: uint8
  discard s.readData(addr b, 1)
  b

proc readU16le(s: Stream): uint16 =
  ## Read 16-bit little-endian.
  let lo = readU8(s).uint16
  let hi = readU8(s).uint16
  lo or (hi shl 8)

proc readU32le(s: Stream): uint32 =
  ## Read 32-bit little-endian.
  let b0 = readU8(s).uint32
  let b1 = readU8(s).uint32
  let b2 = readU8(s).uint32
  let b3 = readU8(s).uint32
  b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)

proc readI32le(s: Stream): int32 =
  ## Read signed 32-bit little-endian.
  cast[int32](readU32le(s))

proc readI64le(s: Stream): int64 =
  ## Read signed 64-bit little-endian.
  let lo = readU32le(s).uint64
  let hi = readU32le(s).uint64
  cast[int64](lo or (hi shl 32))

proc saveState*(snes: SnesBus, cpu: Cpu, slot: int) =
  ## Snapshot current SnesBus public state + Cpu + live APU to the slot file.
  let dir = "bin/states"
  createDir(dir)
  let path = dir / &"slot{slot}.state"
  let stream = newFileStream(path, fmWrite)
  if stream.isNil:
    raise newException(IOError, &"failed to open state for write: {path}")
  defer: stream.close()

  stream.write(StateMagic)
  writeU32le(stream, StateVersion)

  # Cpu (all fields are public)
  writeU16le(stream, cpu.a)
  writeU16le(stream, cpu.x)
  writeU16le(stream, cpu.y)
  writeU16le(stream, cpu.s)
  writeU16le(stream, cpu.d)
  writeU16le(stream, cpu.pc)
  writeU8(stream, cpu.dbr)
  writeU8(stream, cpu.pbr)
  writeU8(stream, cpu.p)
  writeU8(stream, if cpu.emulation: 1'u8 else: 0'u8)
  writeU8(stream, if cpu.stopped: 1'u8 else: 0'u8)
  writeU8(stream, if cpu.waiting: 1'u8 else: 0'u8)
  writeI32le(stream, cpu.mvnBudget.int32)
  writeU8(stream, if cpu.nmiPending: 1'u8 else: 0'u8)

  # Bus WRAM (128KB at 7E0000-7EFFFF / 7F0000-7FFFFF holds all live RAM state)
  let mem = snes.bus.mem
  stream.writeData(unsafeAddr(mem[WramBase]), WramSize)

  # SnesBus public hardware state
  writeU8(stream, snes.nmitimen)

  for i in 0 ..< snes.vram.len:
    writeU16le(stream, snes.vram[i])
  for i in 0 ..< snes.cgram.len:
    writeU16le(stream, snes.cgram[i])
  stream.writeData(unsafeAddr(snes.oam[0]), snes.oam.len)
  stream.writeData(unsafeAddr(snes.ppuRegs[0]), snes.ppuRegs.len)

  for i in 0 ..< snes.bgScroll.len:
    writeU16le(stream, snes.bgScroll[i])
  stream.writeData(unsafeAddr(snes.dmaRegs[0]), snes.dmaRegs.len)
  writeI32le(stream, snes.dmaTransfers.int32)
  writeU8(stream, snes.hdmaen)
  for i in 0 ..< 8:
    writeU32le(stream, snes.hdmaTableAddr[i])
  for i in 0 ..< 8:
    writeU8(stream, snes.hdmaLineCounter[i])
  for i in 0 ..< 8:
    writeU8(stream, if snes.hdmaDoTransfer[i]: 1'u8 else: 0'u8)
  for i in 0 ..< 8:
    writeU16le(stream, snes.hdmaIndirectAddr[i])
  writeU8(stream, snes.fixedColorR)
  writeU8(stream, snes.fixedColorG)
  writeU8(stream, snes.fixedColorB)
  writeU16le(stream, snes.joy1)

  stream.writeData(unsafeAddr(snes.sram[0]), snes.sram.len)
  writeU8(stream, if snes.sramDirty: 1'u8 else: 0'u8)

  stream.writeData(unsafeAddr(snes.apuImage[0]), snes.apuImage.len)
  writeU16le(stream, snes.apuEntry)
  writeI32le(stream, snes.apuUploadBytes.int32)

  writeU32le(stream, snes.apuPostBoot.len.uint32)
  for item in snes.apuPostBoot:
    writeU32le(stream, item[0])
    writeU8(stream, item[1])
  writeU32le(stream, snes.apuJumps.len.uint32)
  for item in snes.apuJumps:
    writeU8(stream, item[0])
    writeU8(stream, item[1])
    writeU16le(stream, item[2])

  # Live APU (public fields only)
  let apu = snes.apu
  for i in 0..3:
    writeU8(stream, apu.portsIn[i])
  for i in 0..3:
    writeU8(stream, apu.portsOut[i])

  let spc = apu.spc
  writeU8(stream, spc.a)
  writeU8(stream, spc.x)
  writeU8(stream, spc.y)
  writeU8(stream, spc.sp)
  writeU16le(stream, spc.pc)
  writeU8(stream, spc.psw)
  writeU8(stream, if spc.stopped: 1'u8 else: 0'u8)
  writeU8(stream, if spc.iplEnabled: 1'u8 else: 0'u8)
  writeI64le(stream, spc.cycles.int64)
  stream.writeData(unsafeAddr(spc.ram[][0]), 0x10000)

  let dsp = apu.dsp
  writeI32le(stream, dsp.writes.int32)
  stream.writeData(unsafeAddr(dsp.regs[0]), dsp.regs.len)

proc loadState*(snes: SnesBus, cpu: var Cpu, slot: int) =
  ## Restore saved state IN-PLACE into the passed SnesBus and Cpu (mutates
  ## existing objects so the slappy audio stream attached to snes.apu at
  ## startup continues to work; no new SnesBus allocation).
  let path = "bin/states" / &"slot{slot}.state"
  let stream = newFileStream(path, fmRead)
  if stream.isNil:
    raise newException(IOError, &"state file not found: {path}")
  defer: stream.close()

  let magic = stream.readStr(4)
  if magic != StateMagic:
    raise newException(ValueError, &"bad state magic (got {magic})")
  let ver = readU32le(stream)
  if ver != StateVersion:
    raise newException(ValueError, &"unsupported state version {ver}")

  cpu.a = readU16le(stream)
  cpu.x = readU16le(stream)
  cpu.y = readU16le(stream)
  cpu.s = readU16le(stream)
  cpu.d = readU16le(stream)
  cpu.pc = readU16le(stream)
  cpu.dbr = readU8(stream)
  cpu.pbr = readU8(stream)
  cpu.p = readU8(stream)
  cpu.emulation = readU8(stream) != 0
  cpu.stopped = readU8(stream) != 0
  cpu.waiting = readU8(stream) != 0
  cpu.mvnBudget = readI32le(stream).int
  cpu.nmiPending = readU8(stream) != 0

  var wramBuf: array[WramSize, uint8]
  discard stream.readData(addr wramBuf[0], WramSize)
  copyMem(addr snes.bus.mem[WramBase], addr wramBuf[0], WramSize)

  snes.nmitimen = readU8(stream)

  for i in 0 ..< snes.vram.len:
    snes.vram[i] = readU16le(stream)
  for i in 0 ..< snes.cgram.len:
    snes.cgram[i] = readU16le(stream)
  discard stream.readData(addr snes.oam[0], snes.oam.len)
  discard stream.readData(addr snes.ppuRegs[0], snes.ppuRegs.len)

  for i in 0 ..< snes.bgScroll.len:
    snes.bgScroll[i] = readU16le(stream)
  discard stream.readData(addr snes.dmaRegs[0], snes.dmaRegs.len)
  snes.dmaTransfers = readI32le(stream).int
  snes.hdmaen = readU8(stream)
  for i in 0 ..< 8:
    snes.hdmaTableAddr[i] = readU32le(stream)
  for i in 0 ..< 8:
    snes.hdmaLineCounter[i] = readU8(stream)
  for i in 0 ..< 8:
    snes.hdmaDoTransfer[i] = readU8(stream) != 0
  for i in 0 ..< 8:
    snes.hdmaIndirectAddr[i] = readU16le(stream)
  snes.fixedColorR = readU8(stream)
  snes.fixedColorG = readU8(stream)
  snes.fixedColorB = readU8(stream)
  snes.joy1 = readU16le(stream)

  discard stream.readData(addr snes.sram[0], snes.sram.len)
  snes.sramDirty = readU8(stream) != 0

  discard stream.readData(addr snes.apuImage[0], snes.apuImage.len)
  snes.apuEntry = readU16le(stream)
  snes.apuUploadBytes = readI32le(stream).int

  let postCount = readU32le(stream).int
  snes.apuPostBoot.setLen(postCount)
  for i in 0 ..< postCount:
    snes.apuPostBoot[i] = (readU32le(stream), readU8(stream))
  let jumpCount = readU32le(stream).int
  snes.apuJumps.setLen(jumpCount)
  for i in 0 ..< jumpCount:
    snes.apuJumps[i] = (readU8(stream), readU8(stream), readU16le(stream))

  for i in 0..3:
    snes.apu.portsIn[i] = readU8(stream)
  for i in 0..3:
    snes.apu.portsOut[i] = readU8(stream)

  snes.apu.spc.a = readU8(stream)
  snes.apu.spc.x = readU8(stream)
  snes.apu.spc.y = readU8(stream)
  snes.apu.spc.sp = readU8(stream)
  snes.apu.spc.pc = readU16le(stream)
  snes.apu.spc.psw = readU8(stream)
  snes.apu.spc.stopped = readU8(stream) != 0
  snes.apu.spc.iplEnabled = readU8(stream) != 0
  snes.apu.spc.cycles = readI64le(stream).int

  var spcRamBuf: array[0x10000, uint8]
  discard stream.readData(addr spcRamBuf[0], 0x10000)
  copyMem(addr snes.apu.spc.ram[][0], addr spcRamBuf[0], 0x10000)

  snes.apu.dsp.writes = readI32le(stream).int
  var dspRegsBuf: array[128, uint8]
  discard stream.readData(addr dspRegsBuf[0], 128)
  copyMem(addr snes.apu.dsp.regs[0], addr dspRegsBuf[0], 128)

proc statePathForSlot*(slot: int): string =
  ## Filesystem path for the given save slot.
  "bin/states" / &"slot{slot}.state"
