## Referee: a DAS=0 (64KiB) A→B MDMA sourced from a WRAM mirror is a poisoned
## CHR-queue job (queue-poison family — the 2026-07-28 credits VRAM spray) and
## must be skipped: no B-bus writes, dma64kSpray sticky, size regs zeroed and
## A-addr advanced as hardware would. Negatives: the same 64KiB job from a ROM
## bank still transfers, and a small WRAM-sourced A→B job (the legitimate CHR
## queue shape) still transfers; neither sets the flag.

import
  std/[os, strformat],
  decompbound/[cpu, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  Sentinel = 0xFF'u8

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc fireMdmaCh0(snes: SnesBus) =
  ## MDMAEN ($420B) write path for channel 0.
  write8(snes.bus, 0x00420B, 0x01)

proc main() =
  ## Spray guard + ROM-source and small-WRAM-job negatives.
  if not fileExists(RomPath):
    echo "[test_dma_64k_spray_guard] SKIP (ROM absent)"
    return

  let snes = newSnesBus(readRom(RomPath))
  discard snes.resetCpu()
  snes.initHdma()
  doAssert not snes.dma64kSpray

  # --- Positive: 64KiB A→B from bank $00 (WRAM mirror start) is skipped ---
  snes.ppuRegs[0x21] = Sentinel     ## CGADD shadow: must stay untouched.
  snes.dmaRegs[0] = 0x01            ## DMAP: A→B, mode 1 (2-byte l/h).
  snes.dmaRegs[1] = 0x21            ## BBAD: $2121 CGADD.
  snes.dmaRegs[2] = 0x00            ## A1T low.
  snes.dmaRegs[3] = 0x00            ## A1T high.
  snes.dmaRegs[4] = 0x00            ## A1B: bank $00 low = WRAM mirror.
  snes.dmaRegs[5] = 0x00            ## DAS = 0 -> 64KiB.
  snes.dmaRegs[6] = 0x00
  fireMdmaCh0(snes)
  doAssert snes.ppuRegs[0x21] == Sentinel,
    &"spray job wrote B-bus: CGADD shadow={snes.ppuRegs[0x21]:02X}"
  doAssert snes.dma64kSpray, "dma64kSpray not set on 64KiB WRAM-sourced A->B"
  doAssert snes.dma64kSprayDmap == 0x01
  doAssert snes.dma64kSprayBbad == 0x21
  doAssert snes.dma64kSprayBank == 0x00
  doAssert snes.dma64kSprayAddr == 0x0000
  doAssert snes.dmaRegs[5] == 0 and snes.dmaRegs[6] == 0,
    "size regs not zeroed after skipped spray job"
  echo &"[test_dma_64k_spray_guard] spray skip ok: " &
    &"DMAP={snes.dma64kSprayDmap:02X} BBAD=21{snes.dma64kSprayBbad:02X} " &
    &"A={snes.dma64kSprayBank:02X}:{snes.dma64kSprayAddr:04X}"

  # --- Negative A: 64KiB from a ROM bank must still transfer ---
  snes.dma64kSpray = false
  snes.initHdma()
  # Mode 0 sends every byte to $2121, so the shadow ends as the LAST source
  # byte ($C0:FFFF). Pick a sentinel guaranteed to differ from it.
  let lastRomByte = snes.bus.mem[0xC0FFFF]
  snes.ppuRegs[0x21] = lastRomByte xor 0x5A
  snes.dmaRegs[0] = 0x00            ## DMAP: A→B, mode 0.
  snes.dmaRegs[1] = 0x21
  snes.dmaRegs[2] = 0x00
  snes.dmaRegs[3] = 0x00
  snes.dmaRegs[4] = 0xC0            ## A1B: ROM bank (HiROM).
  snes.dmaRegs[5] = 0x00            ## DAS = 0 -> 64KiB.
  snes.dmaRegs[6] = 0x00
  fireMdmaCh0(snes)
  doAssert not snes.dma64kSpray, "ROM-sourced 64KiB A->B set dma64kSpray"
  doAssert snes.ppuRegs[0x21] == lastRomByte,
    &"ROM-sourced 64KiB A->B did not transfer: shadow={snes.ppuRegs[0x21]:02X} want {lastRomByte:02X}"
  echo "[test_dma_64k_spray_guard] ROM-source 64KiB negative ok"

  # --- Negative B: small WRAM-sourced A→B (legit CHR job shape) transfers ---
  snes.initHdma()
  for i in 0 ..< 16:
    snes.bus.mem[0x7E0100 + i] = (0xA0 + i).uint8
  snes.ppuRegs[0x21] = Sentinel
  snes.dmaRegs[0] = 0x00            ## DMAP: A→B, mode 0.
  snes.dmaRegs[1] = 0x21
  snes.dmaRegs[2] = 0x00
  snes.dmaRegs[3] = 0x01            ## A1T = $0100.
  snes.dmaRegs[4] = 0x7E
  snes.dmaRegs[5] = 16
  snes.dmaRegs[6] = 0
  fireMdmaCh0(snes)
  doAssert not snes.dma64kSpray, "small WRAM A->B set dma64kSpray"
  doAssert snes.ppuRegs[0x21] == 0xAF,
    &"small WRAM A->B did not land: CGADD shadow={snes.ppuRegs[0x21]:02X} want AF"
  echo "[test_dma_64k_spray_guard] small WRAM-job negative ok"

when isMainModule:
  main()
