## Save/load full emulator state snapshots for the play tool. Uses only
## existing public fields on SnesBus, Cpu and APU (no edits to core files).
## Binary blobs written to bin/states/slotN.state (gitignored).
##
## Refactored so serializeState/deserializeState are the single source of
## truth for the byte layout; saveState/loadState delegate to them for files.

import
  std/[os, streams, strformat],
  ./[apu, cpu, snesbus]

const
  StateMagic* = "DBST"  ## TODO: placeholder magic bytes for decompbound state files.
                        ## Will be refined with proper RE-derived format once needed.
  # v1: no APU timer regs (load left T0 disabled → music driver hang on $FD).
  # v2: append timer0..2 + dspAddr after DSP regs.
  StateVersion* = 2'u32
  StateVersionMin* = 1'u32
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

proc writeState(s: Stream, snes: SnesBus, cpu: Cpu) =
  ## Write the full emulator state to the stream in canonical order.
  ## This is the single serialization implementation shared by
  ## serializeState (for PNG chunks) and saveState (for slot files).
  s.write(StateMagic)
  writeU32le(s, StateVersion)

  # Cpu (all fields are public)
  writeU16le(s, cpu.a)
  writeU16le(s, cpu.x)
  writeU16le(s, cpu.y)
  writeU16le(s, cpu.s)
  writeU16le(s, cpu.d)
  writeU16le(s, cpu.pc)
  writeU8(s, cpu.dbr)
  writeU8(s, cpu.pbr)
  writeU8(s, cpu.p)
  writeU8(s, if cpu.emulation: 1'u8 else: 0'u8)
  writeU8(s, if cpu.stopped: 1'u8 else: 0'u8)
  writeU8(s, if cpu.waiting: 1'u8 else: 0'u8)
  writeI32le(s, cpu.mvnBudget.int32)
  writeU8(s, if cpu.nmiPending: 1'u8 else: 0'u8)

  # Bus WRAM (128KB at 7E0000-7EFFFF / 7F0000-7FFFFF holds all live RAM state)
  let mem = snes.bus.mem
  s.writeData(unsafeAddr(mem[WramBase]), WramSize)

  # SnesBus public hardware state
  writeU8(s, snes.nmitimen)

  for i in 0 ..< snes.vram.len:
    writeU16le(s, snes.vram[i])
  for i in 0 ..< snes.cgram.len:
    writeU16le(s, snes.cgram[i])
  s.writeData(unsafeAddr(snes.oam[0]), snes.oam.len)
  s.writeData(unsafeAddr(snes.ppuRegs[0]), snes.ppuRegs.len)

  for i in 0 ..< snes.bgScroll.len:
    writeU16le(s, snes.bgScroll[i])
  s.writeData(unsafeAddr(snes.dmaRegs[0]), snes.dmaRegs.len)
  writeI32le(s, snes.dmaTransfers.int32)
  writeU8(s, snes.hdmaen)
  for i in 0 ..< 8:
    writeU32le(s, snes.hdmaTableAddr[i])
  for i in 0 ..< 8:
    writeU8(s, snes.hdmaLineCounter[i])
  for i in 0 ..< 8:
    writeU8(s, if snes.hdmaDoTransfer[i]: 1'u8 else: 0'u8)
  for i in 0 ..< 8:
    writeU16le(s, snes.hdmaIndirectAddr[i])
  writeU8(s, snes.fixedColorR)
  writeU8(s, snes.fixedColorG)
  writeU8(s, snes.fixedColorB)
  writeU16le(s, snes.joy1)

  s.writeData(unsafeAddr(snes.sram[0]), snes.sram.len)
  writeU8(s, if snes.sramDirty: 1'u8 else: 0'u8)

  s.writeData(unsafeAddr(snes.apuImage[0]), snes.apuImage.len)
  writeU16le(s, snes.apuEntry)
  writeI32le(s, snes.apuUploadBytes.int32)

  writeU32le(s, snes.apuPostBoot.len.uint32)
  for item in snes.apuPostBoot:
    writeU32le(s, item[0])
    writeU8(s, item[1])
  writeU32le(s, snes.apuJumps.len.uint32)
  for item in snes.apuJumps:
    writeU8(s, item[0])
    writeU8(s, item[1])
    writeU16le(s, item[2])

  # Live APU (public fields only)
  let apu = snes.apu
  for i in 0..3:
    writeU8(s, apu.portsIn[i])
  for i in 0..3:
    writeU8(s, apu.portsOut[i])

  let spc = apu.spc
  writeU8(s, spc.a)
  writeU8(s, spc.x)
  writeU8(s, spc.y)
  writeU8(s, spc.sp)
  writeU16le(s, spc.pc)
  writeU8(s, spc.psw)
  writeU8(s, if spc.stopped: 1'u8 else: 0'u8)
  writeU8(s, if spc.iplEnabled: 1'u8 else: 0'u8)
  writeI64le(s, spc.cycles.int64)
  s.writeData(unsafeAddr(spc.ram[][0]), 0x10000)

  let dsp = apu.dsp
  writeI32le(s, dsp.writes.int32)
  s.writeData(unsafeAddr(dsp.regs[0]), dsp.regs.len)

  # v2: APU timers + DSP address register (needed for music after load-state).
  for i in 0 .. 2:
    let t = apu.getTimerSnapshot(i)
    writeU8(s, if t.enabled: 1'u8 else: 0'u8)
    writeU8(s, t.target)
    writeU8(s, t.internal)
    writeU8(s, t.counter)
    writeI32le(s, t.accum.int32)
  writeU8(s, apu.dspAddr)

proc readState(s: Stream, snes: SnesBus, cpu: var Cpu) =
  ## Read the full emulator state from the stream in canonical order
  ## and restore in-place. Shared by deserializeState and loadState.
  let magic = s.readStr(4)
  if magic != StateMagic:
    raise newException(ValueError, &"bad state magic (got {magic})")
  let ver = readU32le(s)
  if ver < StateVersionMin or ver > StateVersion:
    raise newException(ValueError, &"unsupported state version {ver}")

  cpu.a = readU16le(s)
  cpu.x = readU16le(s)
  cpu.y = readU16le(s)
  cpu.s = readU16le(s)
  cpu.d = readU16le(s)
  cpu.pc = readU16le(s)
  cpu.dbr = readU8(s)
  cpu.pbr = readU8(s)
  cpu.p = readU8(s)
  cpu.emulation = readU8(s) != 0
  cpu.stopped = readU8(s) != 0
  cpu.waiting = readU8(s) != 0
  cpu.mvnBudget = readI32le(s).int
  cpu.nmiPending = readU8(s) != 0

  var wramBuf: array[WramSize, uint8]
  discard s.readData(addr wramBuf[0], WramSize)
  copyMem(addr snes.bus.mem[WramBase], addr wramBuf[0], WramSize)

  snes.nmitimen = readU8(s)

  for i in 0 ..< snes.vram.len:
    snes.vram[i] = readU16le(s)
  for i in 0 ..< snes.cgram.len:
    snes.cgram[i] = readU16le(s)
  discard s.readData(addr snes.oam[0], snes.oam.len)
  discard s.readData(addr snes.ppuRegs[0], snes.ppuRegs.len)

  for i in 0 ..< snes.bgScroll.len:
    snes.bgScroll[i] = readU16le(s)
  discard s.readData(addr snes.dmaRegs[0], snes.dmaRegs.len)
  snes.dmaTransfers = readI32le(s).int
  snes.hdmaen = readU8(s)
  for i in 0 ..< 8:
    snes.hdmaTableAddr[i] = readU32le(s)
  for i in 0 ..< 8:
    snes.hdmaLineCounter[i] = readU8(s)
  for i in 0 ..< 8:
    snes.hdmaDoTransfer[i] = readU8(s) != 0
  for i in 0 ..< 8:
    snes.hdmaIndirectAddr[i] = readU16le(s)
  snes.fixedColorR = readU8(s)
  snes.fixedColorG = readU8(s)
  snes.fixedColorB = readU8(s)
  snes.joy1 = readU16le(s)

  discard s.readData(addr snes.sram[0], snes.sram.len)
  snes.sramDirty = readU8(s) != 0

  discard s.readData(addr snes.apuImage[0], snes.apuImage.len)
  snes.apuEntry = readU16le(s)
  snes.apuUploadBytes = readI32le(s).int

  let postCount = readU32le(s).int
  snes.apuPostBoot.setLen(postCount)
  for i in 0 ..< postCount:
    snes.apuPostBoot[i] = (readU32le(s), readU8(s))
  let jumpCount = readU32le(s).int
  snes.apuJumps.setLen(jumpCount)
  for i in 0 ..< jumpCount:
    snes.apuJumps[i] = (readU8(s), readU8(s), readU16le(s))

  for i in 0..3:
    snes.apu.portsIn[i] = readU8(s)
  for i in 0..3:
    snes.apu.portsOut[i] = readU8(s)

  snes.apu.spc.a = readU8(s)
  snes.apu.spc.x = readU8(s)
  snes.apu.spc.y = readU8(s)
  snes.apu.spc.sp = readU8(s)
  snes.apu.spc.pc = readU16le(s)
  snes.apu.spc.psw = readU8(s)
  snes.apu.spc.stopped = readU8(s) != 0
  snes.apu.spc.iplEnabled = readU8(s) != 0
  snes.apu.spc.cycles = readI64le(s).int

  var spcRamBuf: array[0x10000, uint8]
  discard s.readData(addr spcRamBuf[0], 0x10000)
  copyMem(addr snes.apu.spc.ram[][0], addr spcRamBuf[0], 0x10000)

  snes.apu.dsp.writes = readI32le(s).int
  var dspRegsBuf: array[128, uint8]
  discard s.readData(addr dspRegsBuf[0], 128)
  copyMem(addr snes.apu.dsp.regs[0], addr dspRegsBuf[0], 128)

  if ver >= 2:
    for i in 0 .. 2:
      let enabled = readU8(s) != 0
      let target = readU8(s)
      let internal = readU8(s)
      let counter = readU8(s)
      let accum = readI32le(s).int
      snes.apu.setTimerSnapshot(i, TimerSnapshot(
        enabled: enabled,
        target: target,
        internal: internal,
        counter: counter,
        accum: accum
      ))
    snes.apu.dspAddr = readU8(s)
  else:
    # v1 blobs never stored $F1/$FA–$FC; without T0 the driver hangs on $FD.
    snes.apu.recoverTimersAfterLoad()

  # Mid-upload waits at $C0AB8x: A holds the $2140 byte, CMP waits for echo.
  if cpu.pbr == 0xC0'u8 and cpu.pc >= 0xAB80'u16 and cpu.pc <= 0xAB95'u16:
    snes.apu.resyncPortEchoAfterLoad((cpu.a and 0xFF).uint8)

proc saveState*(snes: SnesBus, cpu: Cpu, slot: int) =
  ## Snapshot current SnesBus public state + Cpu + live APU to the slot file.
  ## Delegates to the single serialize path via writeState.
  let dir = "bin/states"
  createDir(dir)
  let path = dir / &"slot{slot}.state"
  let stream = newFileStream(path, fmWrite)
  if stream.isNil:
    raise newException(IOError, &"failed to open state for write: {path}")
  defer: stream.close()

  writeState(stream, snes, cpu)

proc loadState*(snes: SnesBus, cpu: var Cpu, slot: int) =
  ## Restore saved state IN-PLACE into the passed SnesBus and Cpu (mutates
  ## existing objects so the slappy audio stream attached to snes.apu at
  ## startup continues to work; no new SnesBus allocation).
  ## Delegates to the single deserialize path via readState.
  let path = "bin/states" / &"slot{slot}.state"
  let stream = newFileStream(path, fmRead)
  if stream.isNil:
    raise newException(IOError, &"state file not found: {path}")
  defer: stream.close()

  readState(stream, snes, cpu)

proc serializeState*(snes: SnesBus, cpu: Cpu): seq[byte] =
  ## Serialize current SnesBus public state + Cpu + live APU to a seq[byte].
  ## Uses the exact same field order and layout as the on-disk slot format.
  ## This (with deserializeState) is the single serialization path; file
  ## save/load now delegate here.
  let stream = newStringStream()
  writeState(stream, snes, cpu)
  result = cast[seq[uint8]](stream.data)

proc deserializeState*(data: seq[byte], snes: SnesBus, cpu: var Cpu) =
  ## Deserialize state bytes into the provided SnesBus and Cpu (in-place
  ## mutation so attached audio continues to work). Inverse of serializeState.
  ## Raises on short data, bad magic, or unsupported version (same as load).
  if data.len < 8:
    raise newException(ValueError, "state data too short for magic+version")
  let stream = newStringStream(cast[string](data))
  readState(stream, snes, cpu)

proc statePathForSlot*(slot: int): string =
  ## Filesystem path for the given save slot.
  "bin/states" / &"slot{slot}.state"
