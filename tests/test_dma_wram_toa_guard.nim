## Referee: reverse MDMA (B→A) into a WRAM mirror must not wipe WRAM.
## Synthetic channel: DMAP toA, BBAD at a zeroed PPU shadow, A-bus $0E:0000
## size $100, canary $DC4E at $7E:0020. Fire $420B → canary intact, dmaWramToA
## sticky, size regs zeroed. Negative: normal A→B still transfers and does not
## set the flag.

import
  std/[os, strformat],
  decompbound/[cpu, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  Canary = 0xDC4E'u16
  TransferSize = 0x100

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc wram16(snes: SnesBus, off: int): uint16 =
  ## Little-endian word in bank $7E.
  snes.bus.mem[0x7E0000 + off].uint16 or
    (snes.bus.mem[0x7E0001 + off].uint16 shl 8)

proc writeWram16(snes: SnesBus, off: int, v: uint16) =
  ## Plant a LE word in bank $7E.
  snes.bus.mem[0x7E0000 + off] = (v and 0xFF).uint8
  snes.bus.mem[0x7E0001 + off] = ((v shr 8) and 0xFF).uint8

proc fireMdmaCh0(snes: SnesBus) =
  ## MDMAEN ($420B) write path for channel 0.
  write8(snes.bus, 0x00420B, 0x01)

proc main() =
  ## Guard + negative A→B control.
  if not fileExists(RomPath):
    echo "[test_dma_wram_toa_guard] SKIP (ROM absent)"
    return

  let snes = newSnesBus(readRom(RomPath))
  discard snes.resetCpu()
  snes.initHdma()
  doAssert not snes.dmaWramToA
  doAssert not snes.dmaStorm

  # --- Positive: B→A into bank $0E low mirror must not clear canary ---
  writeWram16(snes, 0x0020, Canary)
  # Zero PPU shadow that BBAD will read (B-bus source of zeros).
  for i in 0 ..< snes.ppuRegs.len:
    snes.ppuRegs[i] = 0
  snes.dmaRegs[0] = 0x80          ## DMAP: B→A, mode 0 (1-byte).
  snes.dmaRegs[1] = 0x00          ## BBAD: $2100 INIDISP shadow.
  snes.dmaRegs[2] = 0x00          ## A1T low.
  snes.dmaRegs[3] = 0x00          ## A1T high.
  snes.dmaRegs[4] = 0x0E          ## A1B: system bank low = WRAM mirror.
  snes.dmaRegs[5] = (TransferSize and 0xFF).uint8
  snes.dmaRegs[6] = ((TransferSize shr 8) and 0xFF).uint8
  fireMdmaCh0(snes)
  doAssert wram16(snes, 0x0020) == Canary,
    &"canary wiped: $0020={wram16(snes, 0x0020):04X} want {Canary:04X}"
  doAssert snes.dmaWramToA, "dmaWramToA not set on reverse MDMA into WRAM"
  doAssert snes.dmaRegs[5] == 0 and snes.dmaRegs[6] == 0,
    "size regs not zeroed after blocked toA transfer"
  doAssert snes.dmaWramToADmap == 0x80
  doAssert snes.dmaWramToABank == 0x0E
  doAssert snes.dmaWramToASize == TransferSize
  echo &"[test_dma_wram_toa_guard] block ok: canary={Canary:04X} " &
    &"dmaWramToA DMAP={snes.dmaWramToADmap:02X} " &
    &"A={snes.dmaWramToABank:02X}:{snes.dmaWramToAAddr:04X} " &
    &"size={snes.dmaWramToASize:04X}"

  # --- Negative: normal A→B must still transfer and not set the flag ---
  snes.dmaWramToA = false
  snes.initHdma()
  # Source pattern in WRAM $7E:0100..
  for i in 0 ..< 16:
    snes.bus.mem[0x7E0100 + i] = (0xA0 + i).uint8
  # Clear CGADD path target via $2121 write tracking — writeBbus updates
  # ppuRegs; plant known dest by reading B-bus writes into CGADD ($2121).
  snes.ppuRegs[0x21] = 0xFF
  snes.dmaRegs[0] = 0x00          ## DMAP: A→B, mode 0.
  snes.dmaRegs[1] = 0x21          ## BBAD: $2121 CGADD.
  snes.dmaRegs[2] = 0x00
  snes.dmaRegs[3] = 0x01          ## A1T = $0100.
  snes.dmaRegs[4] = 0x7E
  snes.dmaRegs[5] = 16
  snes.dmaRegs[6] = 0
  fireMdmaCh0(snes)
  doAssert not snes.dmaWramToA, "normal A→B set dmaWramToA"
  # CGADD was written (last source byte $A0+15 = $AF lands in shadow via port).
  doAssert snes.ppuRegs[0x21] == 0xAF,
    &"A→B did not land: ppuRegs[$21]={snes.ppuRegs[0x21]:02X} want AF"
  doAssert snes.dmaRegs[5] == 0 and snes.dmaRegs[6] == 0
  echo "[test_dma_wram_toa_guard] A->B negative ok (flag clear, CGADD got AF)"

when isMainModule:
  main()
