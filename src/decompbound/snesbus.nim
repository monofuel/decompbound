## SNES system bus for the Earthbound-scoped emulator (Goal 2 milestone 2).
## Layers the HiROM memory map, WRAM mirrors, and MMIO stubs over the flat
## CPU bus. Accuracy grows on demand: registers Earthbound actually touches
## get real behavior; everything else reads open-bus 0.
##
## APU handshake: milestone 3 HLE. The SPC700 boot ROM protocol is faked
## just enough for the game's sound driver upload to proceed.

import
  ./[cpu, memmap, apu]

type
  ApuHandshakeState = enum
    ahsIdle       ## Waiting for the CC kick-off.
    ahsTransfer   ## Echoing transfer counter bytes.
    ahsRunning    ## Driver started: ports read as driver-idle zeros.

  SnesBus* = ref object
    bus*: Bus
    rom*: seq[uint8]
    ## Live audio: the real SPC700 + S-DSP, driven over the $2140-$2143 ports
    ## exactly as on hardware (via the IPL boot ROM). When present it supersedes
    ## the legacy HLE handshake below, so music sequence + samples stay coherent.
    apu*: Apu
    ## MMIO shadow state.
    nmitimen*: uint8
    ## Hardware multiply/divide unit ($4202-$4206 in, $4214-$4217 out).
    mulOperandA: uint8   ## $4202 multiplicand.
    divDividend: uint16  ## $4204/$4205 dividend.
    rddiv: uint16        ## $4214/$4215: divide quotient.
    rdmpy: uint16        ## $4216/$4217: multiply product / divide remainder.
    apuState: ApuHandshakeState
    apuPort0: uint8   ## Last value the CPU wrote to $2140.
    apuPort1: uint8
    apuReadStreak: int  ## Consecutive $2140 reads with no write: the
                        ## post-upload wait loop. After a threshold the
                        ## "driver" comes up and the ports read zero.
    apuPort2: uint8
    apuPort3: uint8
    apuTransferAddr: uint16  ## Current target address from $2142/$2143 during upload.
    apuCounterJustWritten: bool  ## True if a counter was written to $2140; next $2141 is data payload.
    apuExpect: uint8   ## (legacy) Next expected transfer counter.
    apuPendingCounter: int  ## (legacy) $2140 write awaiting its paired $2141 byte.
    apuImage*: array[0x10000, uint8]  ## Reconstructed APU RAM upload.
    apuCursor: int     ## Write position within the current block.
    apuEntry*: uint16  ## Execute address from the final kick (value=0 case).
    apuUploadBytes*: int
    apuPostBoot*: seq[(uint32, uint8)]  ## Port writes after the driver ran.
    apuJumps*: seq[(uint8, uint8, uint16)]  ## (counter, flag, target) pairs for block starts.
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
    hdmaen*: uint8  ## $420C HDMA enable.
    hdmaTableAddr*: array[8, uint32]
    hdmaLineCounter*: array[8, uint8]
    hdmaDoTransfer*: array[8, bool]
    hdmaIndirectAddr*: array[8, uint16]
    fixedColorR*: uint8  ## 0-31 from COLDATA $2132.
    fixedColorG*: uint8
    fixedColorB*: uint8
    hdmaWrites*: seq[(uint32, uint8)]  ## Trace of B-bus writes performed by HDMA (for debug).
    joy1*: uint16  ## Auto-read joypad 1 state ($4218/19). Bit layout:
                   ## high byte B,Y,Sel,Start,U,D,L,R; low byte A,X,L,R.
    sram*: array[0x2000, uint8]  ## 8KB battery SRAM, mirrored across the
                                 ## HiROM SRAM window (banks $20-$3F /
                                 ## $A0-$BF at $6000-$7FFF). Earthbound's
                                 ## anti-piracy check probes exactly this
                                 ## size and mirroring.
    sramDirty*: bool             ## Set on any SRAM write so the player can
                                 ## flush the battery save to a .srm file.

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
    # TODO: magic bytes AA/BB/CC/FF and streak threshold are from IPL
    # protocol + observed EB upload behavior; document the real IPL if
    # we move beyond HLE.
    if snes.apu != nil:
      return snes.apu.portsOut[(offset - 0x2140).int]
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
  of 0x4214:
    (snes.rddiv and 0xFF).uint8   # RDDIVL: divide quotient low.
  of 0x4215:
    (snes.rddiv shr 8).uint8      # RDDIVH: divide quotient high.
  of 0x4216:
    (snes.rdmpy and 0xFF).uint8   # RDMPYL: product / divide remainder low.
  of 0x4217:
    (snes.rdmpy shr 8).uint8      # RDMPYH: product / divide remainder high.
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
proc writeBbus(snes: SnesBus, offset: uint32, value: uint8)

proc writeBbus(snes: SnesBus, offset: uint32, value: uint8) =
  ## Apply a write to B-bus port (from DMA or HDMA). Updates PPU state.
  snes.hdmaWrites.add((offset, value))
  if offset >= 0x2100 and offset <= 0x21FF:
    snes.ppuRegs[(offset - 0x2100).int] = value
    discard snes.ppuPortWrite(offset, value)

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
        snes.writeBbus(bReg, v)
      if not fixed:
        if decrement: aAddr = (aAddr - 1) and 0xFFFF
        else: aAddr = (aAddr + 1) and 0xFFFF
      patternIndex = (patternIndex + 1) mod pattern.len
    snes.dmaRegs[base + 2] = (aAddr and 0xFF).uint8
    snes.dmaRegs[base + 3] = ((aAddr shr 8) and 0xFF).uint8
    snes.dmaRegs[base + 5] = 0
    snes.dmaRegs[base + 6] = 0
    snes.dmaTransfers += 1

proc initHdma*(snes: SnesBus) =
  ## Initialize HDMA channels at the start of a frame for currently enabled ones.
  let en = snes.hdmaen
  for ch in 0..7:
    if (en and (1'u8 shl ch)) == 0:
      snes.hdmaDoTransfer[ch] = false
      continue
    let base = ch * 0x10
    let dmap = snes.dmaRegs[base]
    let indirect = (dmap and 0x40) != 0
    let bank = snes.dmaRegs[base + 4].uint32
    let lo = snes.dmaRegs[base + 2].uint32
    let hi = snes.dmaRegs[base + 3].uint32
    var taddr = (bank shl 16) or lo or (hi shl 8)
    snes.hdmaTableAddr[ch] = taddr
    let count = snes.bus.read8(taddr)
    snes.hdmaLineCounter[ch] = count
    snes.dmaRegs[base + 10] = count
    taddr += 1
    if indirect:
      let ilo = snes.bus.read8(taddr)
      let ihi = snes.bus.read8(taddr + 1)
      snes.hdmaIndirectAddr[ch] = (ilo.uint16) or (ihi.uint16 shl 8)
      snes.dmaRegs[base + 5] = ilo
      snes.dmaRegs[base + 6] = ihi
      taddr += 2
    snes.hdmaTableAddr[ch] = taddr
    snes.dmaRegs[base + 8] = (taddr and 0xFF).uint8
    snes.dmaRegs[base + 9] = ((taddr shr 8) and 0xFF).uint8
    snes.hdmaDoTransfer[ch] = true

proc runHdma*(snes: SnesBus) =
  ## Execute one scanline of HDMA for enabled channels (call for visible lines).
  let en = snes.hdmaen
  if en == 0:
    return
  for ch in 0..7:
    if (en and (1'u8 shl ch)) == 0:
      continue
    let base = ch * 0x10
    let dmap = snes.dmaRegs[base]
    let bbad = snes.dmaRegs[base + 1].uint32
    let indirect = (dmap and 0x40) != 0
    let tmode = dmap and 0x07
    let pat: seq[uint8] = case tmode:
      of 0: @[0'u8]
      of 1: @[0'u8, 1]
      of 2, 6: @[0'u8, 0]
      of 3, 7: @[0'u8, 0, 1, 1]
      of 4: @[0'u8, 1, 2, 3]
      else: @[0'u8, 1, 0, 1]
    if snes.hdmaDoTransfer[ch]:
      for off in pat:
        var v: uint8
        if indirect:
          let ibank = snes.dmaRegs[base + 7].uint32
          let iaddr = (ibank shl 16) or snes.hdmaIndirectAddr[ch].uint32
          v = snes.bus.read8(iaddr)
          snes.hdmaIndirectAddr[ch] = (snes.hdmaIndirectAddr[ch] + 1) and 0xFFFF'u16
          snes.dmaRegs[base + 5] = snes.hdmaIndirectAddr[ch].uint8
          snes.dmaRegs[base + 6] = (snes.hdmaIndirectAddr[ch] shr 8).uint8
        else:
          v = snes.bus.read8(snes.hdmaTableAddr[ch])
          snes.hdmaTableAddr[ch] += 1
          snes.dmaRegs[base + 8] = (snes.hdmaTableAddr[ch] and 0xFF).uint8
          snes.dmaRegs[base + 9] = ((snes.hdmaTableAddr[ch] shr 8) and 0xFF).uint8
        let port = 0x2100'u32 + bbad + off.uint32
        snes.writeBbus(port, v)
    # decrement and decide next
    var ctr = snes.hdmaLineCounter[ch]
    if ctr > 0:
      ctr -= 1
    snes.hdmaLineCounter[ch] = ctr
    snes.dmaRegs[base + 10] = ctr
    let rep = (ctr and 0x80) != 0
    snes.hdmaDoTransfer[ch] = rep
    if (ctr and 0x7F) == 0:
      var taddr = snes.hdmaTableAddr[ch]
      let nextc = snes.bus.read8(taddr)
      snes.hdmaLineCounter[ch] = nextc
      snes.dmaRegs[base + 10] = nextc
      taddr += 1
      if nextc == 0:
        snes.hdmaDoTransfer[ch] = false
        snes.hdmaTableAddr[ch] = taddr
        snes.dmaRegs[base + 8] = (taddr and 0xFF).uint8
        snes.dmaRegs[base + 9] = ((taddr shr 8) and 0xFF).uint8
        continue
      if indirect:
        let ilo = snes.bus.read8(taddr)
        let ihi = snes.bus.read8(taddr + 1)
        snes.hdmaIndirectAddr[ch] = ilo.uint16 or (ihi.uint16 shl 8)
        snes.dmaRegs[base + 5] = ilo
        snes.dmaRegs[base + 6] = ihi
        taddr += 2
      snes.hdmaTableAddr[ch] = taddr
      snes.dmaRegs[base + 8] = (taddr and 0xFF).uint8
      snes.dmaRegs[base + 9] = ((taddr shr 8) and 0xFF).uint8
      snes.hdmaDoTransfer[ch] = true

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
  if offset == 0x420C:
    snes.hdmaen = value
    return
  # Hardware multiply/divide unit. EarthBound's menu (and much game logic) does
  # 8x8 multiplies and 16/8 divides through these; without them, result reads
  # return 0 and layout/selection loops hang. Results are available immediately
  # (we ignore the 8/16-cycle hardware latency).
  if offset == 0x4202:
    snes.mulOperandA = value       # WRMPYA: multiplicand.
    return
  if offset == 0x4203:
    # WRMPYB: multiplier; writing it starts the 8x8 unsigned multiply.
    snes.rdmpy = snes.mulOperandA.uint16 * value.uint16
    return
  if offset == 0x4204:
    snes.divDividend = (snes.divDividend and 0xFF00) or value.uint16
    return
  if offset == 0x4205:
    snes.divDividend = (snes.divDividend and 0x00FF) or (value.uint16 shl 8)
    return
  if offset == 0x4206:
    # WRDIVB: divisor; writing it starts the 16/8 unsigned divide. Quotient ->
    # RDDIV ($4214/5), remainder -> RDMPY ($4216/7). Divide-by-zero yields the
    # hardware result: quotient $FFFF, remainder = dividend.
    if value == 0:
      snes.rddiv = 0xFFFF
      snes.rdmpy = snes.divDividend
    else:
      snes.rddiv = snes.divDividend div value.uint16
      snes.rdmpy = snes.divDividend mod value.uint16
    return
  if offset == 0x2132:
    # COLDATA: accumulate components as per hardware (bits 7/6/5 select R/G/B).
    if (value and 0x80) != 0:
      snes.fixedColorR = value and 0x1F
    if (value and 0x40) != 0:
      snes.fixedColorG = value and 0x1F
    if (value and 0x20) != 0:
      snes.fixedColorB = value and 0x1F
  # Live APU: forward S-CPU port writes straight to the SPC700 input ports and
  # skip the legacy HLE capture. The real driver + IPL handle the protocol.
  if snes.apu != nil and offset >= 0x2140 and offset <= 0x2143:
    snes.apu.portsIn[(offset - 0x2140).int] = value
    return
  case offset:
  of 0x2140:
    # The CC kick-off starts the transfer protocol; afterwards the boot
    # ROM echoes the counter the CPU writes. When the game writes $FF to
    # a running driver it commands a return to the boot ROM (the reboot
    # used between intro screens to upload new music).
    #
    # Upload capture (for standalone SPC player): EB's uploader at $C0AB06
    # sends block headers (addr in $2142/3 + flag in $2141) then data.
    # Data bytes arrive via 16-bit writes to $2140 (low=counter, high=data
    # on $2141). We use write *order* (2140 then 2141 = data; 2141 then
    # 2140 = header cmd) to distinguish without relying on exact counters.
    # TODO: magic 0xCC/0xFF and IPL details; replace with full protocol
    # reverse if we need more than EB uploads.
    if snes.apuState == ahsIdle and value == 0xCC:
      snes.apuState = ahsTransfer
      snes.apuCursor = (snes.apuPort3.int shl 8) or snes.apuPort2.int
      snes.apuTransferAddr = (snes.apuPort3.uint16 shl 8) or snes.apuPort2.uint16
      snes.apuExpect = 0
      snes.apuPendingCounter = -1
      snes.apuCounterJustWritten = false
      # If the preceding 2141 was a 0 flag for this first block, capture entry.
      if snes.apuPort1 == 0:
        snes.apuEntry = snes.apuTransferAddr
    elif snes.apuState == ahsRunning and value == 0xFF:
      snes.apuState = ahsIdle
    elif snes.apuState == ahsTransfer:
      # Counter written (start of data pair or header cmd terminator).
      snes.apuCounterJustWritten = true
      snes.apuPendingCounter = value.int
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2140'u32, value)
    snes.apuPort0 = value
    snes.apuReadStreak = 0
  of 0x2141:
    if snes.apuState == ahsTransfer:
      if snes.apuCounterJustWritten:
        # 2140 (counter) then 2141 (payload): this is a data byte from the
        # game's 16-bit STA to $2140. Deposit it.
        snes.apuImage[snes.apuCursor and 0xFFFF] = value
        snes.apuCursor += 1
        snes.apuUploadBytes += 1
        snes.apuCounterJustWritten = false
      else:
        # 2141 written before its 2140: this is a block header command.
        # $2142/3 were written just before with the target address.
        let target = (snes.apuPort3.uint16 shl 8) or snes.apuPort2.uint16
        snes.apuTransferAddr = target
        snes.apuCursor = target.int
        if value == 0:
          snes.apuEntry = target
        # Record for debug / analysis (real block starts, not every byte).
        let counter = if snes.apuPendingCounter >= 0: snes.apuPendingCounter.uint8 else: 0'u8
        snes.apuJumps.add (counter, value, target)
        snes.apuCounterJustWritten = false
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2141'u32, value)
    snes.apuPort1 = value
    snes.apuReadStreak = 0
  of 0x2142:
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2142'u32, value)
    snes.apuPort2 = value
    if snes.apuState == ahsTransfer:
      snes.apuTransferAddr = (snes.apuPort3.uint16 shl 8) or snes.apuPort2.uint16
  of 0x2143:
    if snes.apuState == ahsRunning:
      snes.apuPostBoot.add (0x2143'u32, value)
    snes.apuPort3 = value
    if snes.apuState == ahsTransfer:
      snes.apuTransferAddr = (snes.apuPort3.uint16 shl 8) or snes.apuPort2.uint16
  of 0x4200:
    snes.nmitimen = value
  else:
    discard

proc detectLoRom(rom: seq[uint8]): bool =
  ## Detect the cartridge map mode from the internal header. The header sits at
  ## file $FFC0 (HiROM) or $7FC0 (LoROM); score each candidate by a valid
  ## checksum/complement pair (they must sum to $FFFF), the map-mode bit, and a
  ## printable title, then pick the better. EarthBound (HiROM) scores at $FFC0;
  ## generic LoROM test ROMs score at $7FC0. A ROM too small to hold a $FFC0
  ## header can only be LoROM.
  proc score(base: int): int =
    if base + 0x20 > rom.len: return -1
    let complement = rom[base + 0x1C].int or (rom[base + 0x1D].int shl 8)
    let checksum = rom[base + 0x1E].int or (rom[base + 0x1F].int shl 8)
    let mapByte = rom[base + 0x15].int
    result = 0
    if checksum != 0 and (complement + checksum) == 0xFFFF:
      result += 8
    # Map-mode bit 0: 1 = HiROM. The HiROM header lives at $FFC0, LoROM at $7FC0.
    let wantsHi = base == 0xFFC0
    if ((mapByte and 1) != 0) == wantsHi:
      result += 2
    var printable = 0
    for i in 0 ..< 21:
      let c = rom[base + i]
      if c >= 0x20'u8 and c < 0x7F'u8:
        inc printable
    if printable >= 16:
      result += 1
  result = score(0x7FC0) > score(0xFFC0)

proc newSnesBus*(rom: seq[uint8]): SnesBus =
  ## Build the SNES bus: ROM copied into its mirror layout (HiROM for EarthBound,
  ## LoROM for generic test ROMs), WRAM live in banks $7E/$7F, low-RAM/MMIO
  ## windows hooked in the system banks.
  let snes = SnesBus(bus: newBus(), rom: rom)

  if detectLoRom(rom):
    # LoROM: each 32KB file chunk maps to the upper half ($8000-$FFFF) of a
    # sequential bank, present in $00-$7D and mirrored into $80-$FF.
    for fileOffset in 0..<rom.len:
      let chunk = fileOffset div 0x8000
      let bankAddr = 0x8000 + (fileOffset mod 0x8000)
      if chunk <= 0x7D:
        snes.bus.mem[((chunk shl 16) or bankAddr).int] = rom[fileOffset]
      let hiBank = chunk + 0x80
      if hiBank <= 0xFF:
        snes.bus.mem[((hiBank shl 16) or bankAddr).int] = rom[fileOffset]
  else:
    # HiROM (EarthBound): ROM into banks C0-FF (full) + the read mirrors.
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
        snes.sramDirty = true
        return true
      if offset >= 0x8000:
        return true  # ROM: ignore writes.
      return false
    # Banks 40-7D and C0-FF above the system area are ROM: ignore writes.
    result = true

  snes.hdmaen = 0
  for i in 0..<8:
    snes.hdmaDoTransfer[i] = false
    snes.hdmaTableAddr[i] = 0
    snes.hdmaLineCounter[i] = 0
    snes.hdmaIndirectAddr[i] = 0
  snes.fixedColorR = 0
  snes.fixedColorG = 0
  snes.fixedColorB = 0
  snes.hdmaWrites = @[]

  # APU HLE state (clean for each fresh bus / boot capture).
  snes.apuState = ahsIdle
  snes.apuPort0 = 0
  snes.apuPort1 = 0
  snes.apuPort2 = 0
  snes.apuPort3 = 0
  snes.apuTransferAddr = 0
  snes.apuCounterJustWritten = false
  snes.apuReadStreak = 0
  snes.apuExpect = 0
  snes.apuPendingCounter = -1
  snes.apuCursor = 0
  snes.apuEntry = 0
  snes.apuUploadBytes = 0
  snes.apuPostBoot = @[]
  snes.apuJumps = @[]
  # apuImage zeros by default.

  # Live two-way APU: real SPC700 + DSP, cold-booted through the IPL ROM. From
  # here the main CPU speaks the real upload protocol over $2140-$2143.
  snes.apu = newApu()
  snes.apu.bootWithIpl()

  result = snes

proc resetCpu*(snes: SnesBus): Cpu =
  ## CPU state at power-on: emulation mode, reset vector from $00:FFFC. Read
  ## through the mapped bus memory (not the raw file), so it is correct for both
  ## HiROM and LoROM layouts and can never index past a short ROM.
  result.emulation = true
  result.p = FlagM or FlagX or FlagI
  result.s = 0x01FF
  result.pc = snes.bus.mem[0xFFFC].uint16 or (snes.bus.mem[0xFFFD].uint16 shl 8)
  result.pbr = 0
  result.dbr = 0

proc tickApu*(snes: SnesBus): tuple[left, right: int16] =
  ## Advance the live APU by one 32kHz sample (SPC700 + timers + DSP) and return
  ## the mixed stereo sample. Call SamplesPerFrame (~533) times per emulated
  ## frame so the APU boot handshake and the music driver run in step with the
  ## main CPU. Boot/render loops that don't need audio can discard the result;
  ## play.nim streams it to the speakers. No-op (returns 0) if no live APU.
  if snes.apu == nil:
    return (0'i16, 0'i16)
  snes.apu.runSample()
