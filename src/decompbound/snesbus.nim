## SNES system bus for the Earthbound-scoped emulator (Goal 2 milestone 2).
## Layers the HiROM memory map, WRAM mirrors, and MMIO stubs over the flat
## CPU bus. Accuracy grows on demand: registers Earthbound actually touches
## get real behavior; everything else reads open-bus 0.
##
## APU handshake: milestone 3 HLE. The SPC700 boot ROM protocol is faked
## just enough for the game's sound driver upload to proceed.

import
  ./[cpu, memmap]

type
  ApuHandshakeState = enum
    ahsIdle       ## Waiting for the CC kick-off.
    ahsTransfer   ## Echoing transfer counter bytes.
    ahsRunning    ## Driver started: ports read as driver-idle zeros.

  SnesBus* = ref object
    bus*: Bus
    rom*: seq[uint8]
    ## MMIO shadow state.
    nmitimen*: uint8
    apuState: ApuHandshakeState
    apuPort0: uint8   ## Last value the CPU wrote to $2140.
    apuPort1: uint8
    apuReadStreak: int  ## Consecutive $2140 reads with no write: the
                        ## post-upload wait loop. After a threshold the
                        ## "driver" comes up and the ports read zero.
    apuPort2: uint8
    apuPort3: uint8
    apuExpect: uint8   ## Next expected transfer counter.
    apuPendingCounter: int  ## $2140 write awaiting its paired $2141 byte.
    apuImage*: array[0x10000, uint8]  ## Reconstructed APU RAM upload.
    apuCursor: int     ## Write position within the current block.
    apuEntry*: uint16  ## Execute address from the final kick.
    apuUploadBytes*: int
    apuPostBoot*: seq[(uint32, uint8)]  ## Port writes after the driver ran.
    apuJumps*: seq[(uint8, uint8, uint16)]  ## (counter, flag, target) pairs.
    vblankToggle: bool
    mmioReads*: seq[uint32]   ## Trace of MMIO reads (debug aid).
    mmioWrites*: seq[(uint32, uint8)]  ## Trace of MMIO writes.
    ## PPU memory.
    vram*: array[0x8000, uint16]   ## 64KB as 32K words.
    cgram*: array[256, uint16]     ## 256 BGR555 palette entries.
    oam*: array[544, uint8]        ## 512 + 32 bytes of sprite tables.
    ## PPU port state.
    ppuRegs*: array[0x100, uint8]  ## Raw shadow of $21xx writes.
    bgScroll*: array[8, uint16]  ## Latched BG1-4 H/V offsets ($210D-$2114).
    bgScrollLatch: uint8         ## Shared write-twice prev-byte latch.
    vmain: uint8
    vmadd: uint16
    cgadd: uint16
    cgLatch: int      ## -1 when no low byte is pending.
    oamAddr: uint16
    ## DMA channel registers, 8 channels x $43x0-$43x7.
    dmaRegs*: array[0x80, uint8]
    dmaTransfers*: int  ## Count of completed DMA transfers (debug aid).
    joy1*: uint16  ## Auto-read joypad 1 state ($4218/19). Bit layout:
                   ## high byte B,Y,Sel,Start,U,D,L,R; low byte A,X,L,R.
    sram*: array[0x2000, uint8]  ## 8KB battery SRAM, mirrored across the
                                 ## HiROM SRAM window (banks $20-$3F /
                                 ## $A0-$BF at $6000-$7FFF). Earthbound's
                                 ## anti-piracy check probes exactly this
                                 ## size and mirroring.

proc isMmio(offset: uint32): bool =
  ## System-area registers: $2100-$21FF (PPU/APU), $4000-$44FF (CPU/DMA).
  (offset >= 0x2100 and offset <= 0x21FF) or
    (offset >= 0x4000 and offset <= 0x44FF)

proc mmioRead(snes: SnesBus, offset: uint32): uint8 =
  ## Read an MMIO register. Stubs return plausible idle values so boot
  ## code polling hardware status can make progress.
  snes.mmioReads.add offset
  case offset:
  of 0x2140, 0x2141, 0x2142, 0x2143:
    # APU ports: SPC700 boot ROM handshake HLE. The boot ROM announces
    # readiness with AA/BB, then echoes whatever the CPU last wrote.
    # When the CPU stops writing and just polls (the wait-for-driver
    # loop at $C0AB90), the uploaded driver "boots" and zeros the ports.
    case snes.apuState:
    of ahsIdle:
      if offset == 0x2140: 0xAA'u8 else: 0xBB'u8
    of ahsTransfer:
      snes.apuReadStreak += 1
      if snes.apuReadStreak > 64:
        snes.apuState = ahsRunning
        return 0
      if offset == 0x2140: snes.apuPort0 else: snes.apuPort1
    of ahsRunning:
      0x00'u8
  of 0x4210:
    # RDNMI: NMI flag toggles so vblank wait loops make progress.
    snes.vblankToggle = not snes.vblankToggle
    if snes.vblankToggle: 0xC2'u8 else: 0x42'u8
  of 0x4211:
    0x00  # TIMEUP: no IRQ pending.
  of 0x4218:
    (snes.joy1 and 0xFF).uint8
  of 0x4219:
    (snes.joy1 shr 8).uint8
  of 0x4212:
    # HVBJOY: toggle vblank/hblank bits so polls terminate.
    snes.vblankToggle = not snes.vblankToggle
    if snes.vblankToggle: 0x81'u8 else: 0x00'u8
  else:
    0x00

proc vramIncrement(snes: SnesBus, highWrite: bool) =
  ## Advance VMADD per VMAIN increment mode.
  let incAfterHigh = (snes.vmain and 0x80) != 0
  if highWrite == incAfterHigh:
    let step = case snes.vmain and 0x03:
      of 0: 1'u16
      of 1: 32'u16
      else: 128'u16
    snes.vmadd = snes.vmadd + step

proc ppuPortWrite(snes: SnesBus, offset: uint32, value: uint8): bool =
  ## Handle PPU data-port writes that fill VRAM/CGRAM/OAM.
  case offset:
  of 0x2102:
    snes.oamAddr = (snes.oamAddr and 0x0200) or (value.uint16 shl 1)
    true
  of 0x2103:
    snes.oamAddr = ((value.uint16 and 1) shl 9) or (snes.oamAddr and 0x1FF)
    true
  of 0x2104:
    if snes.oamAddr < 544:
      snes.oam[snes.oamAddr] = value
    snes.oamAddr = (snes.oamAddr + 1) and 0x3FF
    true
  of 0x210D, 0x210E, 0x210F, 0x2110, 0x2111, 0x2112, 0x2113, 0x2114:
    # BG scroll registers are write-twice through a shared latch:
    # low byte first, then high; full value assembles on the second write.
    let index = (offset - 0x210D).int
    snes.bgScroll[index] =
      ((value.uint16 shl 8) or snes.bgScrollLatch.uint16) and 0x3FF
    snes.bgScrollLatch = value
    true
  of 0x2115:
    snes.vmain = value
    true
  of 0x2116:
    snes.vmadd = (snes.vmadd and 0xFF00) or value.uint16
    true
  of 0x2117:
    snes.vmadd = (snes.vmadd and 0x00FF) or (value.uint16 shl 8)
    true
  of 0x2118:
    let index = (snes.vmadd and 0x7FFF).int
    snes.vram[index] = (snes.vram[index] and 0xFF00) or value.uint16
    snes.vramIncrement(highWrite = false)
    true
  of 0x2119:
    let index = (snes.vmadd and 0x7FFF).int
    snes.vram[index] = (snes.vram[index] and 0x00FF) or (value.uint16 shl 8)
    snes.vramIncrement(highWrite = true)
    true
  of 0x2121:
    snes.cgadd = value.uint16
    snes.cgLatch = -1
    true
  of 0x2122:
    if snes.cgLatch < 0:
      snes.cgLatch = value.int
    else:
      snes.cgram[snes.cgadd and 0xFF] =
        snes.cgLatch.uint16 or (value.uint16 shl 8)
      snes.cgadd = (snes.cgadd + 1) and 0xFF
      snes.cgLatch = -1
    true
  else:
    false

proc mmioWrite(snes: SnesBus, offset: uint32, value: uint8)

proc runDma(snes: SnesBus, channels: uint8) =
  ## Execute enabled general-purpose DMA channels instantly.
  for ch in 0..7:
    if (channels and (1'u8 shl ch)) == 0:
      continue
    let base = ch * 0x10
    let dmap = snes.dmaRegs[base]
    let bbad = snes.dmaRegs[base + 1]
    var aAddr = snes.dmaRegs[base + 2].uint32 or
      (snes.dmaRegs[base + 3].uint32 shl 8)
    let aBank = snes.dmaRegs[base + 4].uint32
    var size = snes.dmaRegs[base + 5].int or (snes.dmaRegs[base + 6].int shl 8)
    if size == 0:
      size = 0x10000
    let fixed = (dmap and 0x08) != 0
    let decrement = (dmap and 0x10) != 0
    let toA = (dmap and 0x80) != 0
    # B-bus register sequence per transfer pattern.
    let pattern: seq[uint8] = case dmap and 0x07:
      of 0: @[0'u8]
      of 1: @[0'u8, 1]
      of 2, 6: @[0'u8, 0]
      of 3, 7: @[0'u8, 0, 1, 1]
      of 4: @[0'u8, 1, 2, 3]
      else: @[0'u8, 1, 0, 1]
    var patternIndex = 0
    for i in 0..<size:
      let bReg = 0x2100'u32 + bbad.uint32 + pattern[patternIndex].uint32
      let aFull = (aBank shl 16) or (aAddr and 0xFFFF)
      if toA:
        # B to A: rare in boot paths; read the shadow.
        let v = snes.ppuRegs[(bReg - 0x2100).int]
        if not snes.bus.writeHook(aFull, v):
          snes.bus.mem[aFull.int] = v
      else:
        var v: uint8
        let hooked = snes.bus.readHook(aFull)
        v = if hooked >= 0: hooked.uint8 else: snes.bus.mem[aFull.int]
        snes.mmioWrite(bReg, v)
      if not fixed:
        if decrement: aAddr = (aAddr - 1) and 0xFFFF
        else: aAddr = (aAddr + 1) and 0xFFFF
      patternIndex = (patternIndex + 1) mod pattern.len
    snes.dmaRegs[base + 2] = (aAddr and 0xFF).uint8
    snes.dmaRegs[base + 3] = ((aAddr shr 8) and 0xFF).uint8
    snes.dmaRegs[base + 5] = 0
    snes.dmaRegs[base + 6] = 0
    snes.dmaTransfers += 1

proc mmioWrite(snes: SnesBus, offset: uint32, value: uint8) =
  ## Write an MMIO register.
  snes.mmioWrites.add (offset, value)
  if offset >= 0x2100 and offset <= 0x21FF:
    snes.ppuRegs[(offset - 0x2100).int] = value
    if snes.ppuPortWrite(offset, value):
      return
  if offset >= 0x4300 and offset <= 0x437F:
    snes.dmaRegs[(offset - 0x4300).int] = value
    return
  if offset == 0x420B:
    snes.runDma(value)
    return
  case offset:
  of 0x2140:
    # The CC kick-off starts the transfer protocol; afterwards the boot
    # ROM echoes the counter the CPU writes. When the game writes $FF to
    # a running driver it commands a return to the boot ROM (the reboot
    # used between intro screens to upload new music). The IPL protocol
    # is also parsed here to reconstruct the APU RAM image: data bytes
    # arrive on $2141 with consecutive counters on $2140; a counter jump
    # starts a new block at the address in $2142/43 ($2141 nonzero) or
    # executes there ($2141 zero).
    if snes.apuState == ahsIdle and value == 0xCC:
      snes.apuState = ahsTransfer
      snes.apuCursor = (snes.apuPort3.int shl 8) or snes.apuPort2.int
      snes.apuExpect = 0
      snes.apuPendingCounter = -1
    elif snes.apuState == ahsRunning and value == 0xFF:
      snes.apuState = ahsIdle
    elif snes.apuState == ahsTransfer:
      # The game uploads with 16-bit stores: counter lands here first,
      # its paired data byte lands on $2141 next.
      snes.apuPendingCounter = value.int
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2140'u32, value)
    snes.apuPort0 = value
    snes.apuReadStreak = 0
  of 0x2141:
    if snes.apuState == ahsTransfer and snes.apuPendingCounter >= 0:
      let counter = snes.apuPendingCounter.uint8
      snes.apuPendingCounter = -1
      if counter == snes.apuExpect:
        snes.apuImage[snes.apuCursor and 0xFFFF] = value
        snes.apuCursor += 1
        snes.apuUploadBytes += 1
        snes.apuExpect = counter + 1
      else:
        # Counter jump pair: data byte 0 = execute, nonzero = new block.
        let target = (snes.apuPort3.uint16 shl 8) or snes.apuPort2.uint16
        snes.apuJumps.add (counter, value, target)
        if value == 0:
          snes.apuEntry = target
        else:
          snes.apuCursor = target.int
        # Each block restarts its transfer counter at zero.
        snes.apuExpect = 0
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2141'u32, value)
    snes.apuPort1 = value
    snes.apuReadStreak = 0
  of 0x2142:
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2142'u32, value)
    snes.apuPort2 = value
  of 0x2143:
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2143'u32, value)
    snes.apuPort3 = value
  of 0x4200:
    snes.nmitimen = value
  else:
    discard

proc newSnesBus*(rom: seq[uint8]): SnesBus =
  ## Build the SNES bus: ROM copied into every HiROM mirror, WRAM live in
  ## banks $7E/$7F, low-RAM/MMIO windows hooked in the system banks.
  let snes = SnesBus(bus: newBus(), rom: rom)

  # ROM into banks C0-FF (full) and the read mirrors.
  for fileOffset in 0..<rom.len:
    let snesAddr = fileToSnes(fileOffset)
    snes.bus.mem[snesAddr.int] = rom[fileOffset]
    # Banks 40-7D mirror C0-FD fully (7E/7F are WRAM, excluded).
    let mirrorBank = (snesAddr shr 16) - 0x80
    if mirrorBank <= 0x7D:
      snes.bus.mem[((mirrorBank shl 16) or (snesAddr and 0xFFFF)).int] =
        rom[fileOffset]
    # Upper halves of banks 00-3F and 80-BF.
    if (snesAddr and 0xFFFF) >= 0x8000:
      let bank = (snesAddr shr 16) and 0x3F
      snes.bus.mem[((bank shl 16) or (snesAddr and 0xFFFF)).int] = rom[fileOffset]
      snes.bus.mem[(((bank + 0x80) shl 16) or (snesAddr and 0xFFFF)).int] =
        rom[fileOffset]

  snes.bus.readHook = proc(address: uint32): int =
    let bank = address shr 16
    let offset = address and 0xFFFF
    if bank == 0x7E or bank == 0x7F:
      return -1  # WRAM, flat.
    if (bank <= 0x3F) or (bank >= 0x80 and bank <= 0xBF):
      if offset < 0x2000:
        # Low RAM mirrors WRAM $7E:0000-$1FFF.
        return snes.bus.mem[(0x7E0000'u32 or offset).int].int
      if isMmio(offset):
        return snes.mmioRead(offset).int
      if offset >= 0x6000 and offset < 0x8000 and (bank and 0x3F) >= 0x20:
        return snes.sram[(offset - 0x6000).int].int
    result = -1

  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let offset = address and 0xFFFF
    if bank == 0x7E or bank == 0x7F:
      return false  # WRAM, flat.
    if (bank <= 0x3F) or (bank >= 0x80 and bank <= 0xBF):
      if offset < 0x2000:
        snes.bus.mem[(0x7E0000'u32 or offset).int] = value
        return true
      if isMmio(offset):
        snes.mmioWrite(offset, value)
        return true
      if offset >= 0x6000 and offset < 0x8000 and (bank and 0x3F) >= 0x20:
        snes.sram[(offset - 0x6000).int] = value
        return true
      if offset >= 0x8000:
        return true  # ROM: ignore writes.
      return false
    # Banks 40-7D and C0-FF above the system area are ROM: ignore writes.
    result = true

  result = snes

proc resetCpu*(snes: SnesBus): Cpu =
  ## CPU state at power-on: emulation mode, vector from $FFFC.
  result.emulation = true
  result.p = FlagM or FlagX or FlagI
  result.s = 0x01FF
  result.pc = snes.rom[0xFFFC].uint16 or (snes.rom[0xFFFD].uint16 shl 8)
  result.pbr = 0
  result.dbr = 0
