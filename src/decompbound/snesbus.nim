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
    vblankToggle: bool
    mmioReads*: seq[uint32]   ## Trace of MMIO reads (debug aid).
    mmioWrites*: seq[(uint32, uint8)]  ## Trace of MMIO writes.

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
  of 0x4212:
    # HVBJOY: toggle vblank/hblank bits so polls terminate.
    snes.vblankToggle = not snes.vblankToggle
    if snes.vblankToggle: 0x81'u8 else: 0x00'u8
  else:
    0x00

proc mmioWrite(snes: SnesBus, offset: uint32, value: uint8) =
  ## Write an MMIO register.
  snes.mmioWrites.add (offset, value)
  case offset:
  of 0x2140:
    # The CC kick-off starts the transfer protocol; afterwards the boot
    # ROM echoes the counter the CPU writes.
    if snes.apuState == ahsIdle and value == 0xCC:
      snes.apuState = ahsTransfer
    snes.apuPort0 = value
    snes.apuReadStreak = 0
  of 0x2141:
    snes.apuPort1 = value
    snes.apuReadStreak = 0
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
