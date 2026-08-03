## Referee: MDMA per-frame byte budget trips dmaStorm without melting the host.
## Synthetic storm path (many 64KB channels in one frame window) must set
## dmaStorm and stay fast; a normal 8KB transfer must not. initHdma resets the
## byte counter (not the sticky storm flag).

import
  std/[monotimes, os, strformat, times],
  decompbound/[cpu, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StormFires = 30
    ## 30 × 64KB = 1.875 MiB > MaxDmaBytesPerFrame (1 MiB).
  NormalSize = 8192
  StormWallMs = 500
    ## Host must not spend hundreds of ms on stormed MDMA.

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc setupChannel0(snes: SnesBus, size: int) =
  ## Channel 0: 1-byte pattern → $2121 (CGADD, safe B-bus), A-bus from WRAM.
  snes.dmaRegs[0] = 0x00          ## DMAP: A→B, 1-byte, increment.
  snes.dmaRegs[1] = 0x21          ## BBAD: $2121 CGADD.
  snes.dmaRegs[2] = 0x00          ## A1T low.
  snes.dmaRegs[3] = 0x00          ## A1T high.
  snes.dmaRegs[4] = 0x7E          ## A1B: WRAM bank.
  if size == 0:
    snes.dmaRegs[5] = 0
    snes.dmaRegs[6] = 0
  else:
    snes.dmaRegs[5] = (size and 0xFF).uint8
    snes.dmaRegs[6] = ((size shr 8) and 0xFF).uint8

proc fireMdmaCh0(snes: SnesBus) =
  ## MDMAEN ($420B) write path for channel 0.
  write8(snes.bus, 0x00420B, 0x01)

proc main() =
  ## Storm budget + normal-frame negative control + initHdma reset.
  if not fileExists(RomPath):
    echo "[test_dma_storm_budget] SKIP (ROM absent)"
    return

  let snes = newSnesBus(readRom(RomPath))
  discard snes.resetCpu()
  snes.initHdma()
  doAssert snes.dmaBytesThisFrame == 0
  doAssert not snes.dmaStorm

  # --- Normal frame: one 8KB transfer must not trip the budget ---
  setupChannel0(snes, NormalSize)
  fireMdmaCh0(snes)
  doAssert not snes.dmaStorm,
    &"normal 8KB set dmaStorm (bytes={snes.dmaBytesThisFrame})"
  doAssert snes.dmaBytesThisFrame == NormalSize,
    &"normal bytes={snes.dmaBytesThisFrame} want {NormalSize}"
  snes.initHdma()
  doAssert snes.dmaBytesThisFrame == 0
  doAssert not snes.dmaStorm

  # --- Storm: many 64KB (size-reg 0) fires without initHdma ---
  let t0 = getMonoTime()
  for i in 0 ..< StormFires:
    setupChannel0(snes, 0)
    fireMdmaCh0(snes)
  let ms = (getMonoTime() - t0).inMilliseconds
  doAssert snes.dmaStorm, "storm path never set dmaStorm"
  doAssert snes.dmaBytesThisFrame > MaxDmaBytesPerFrame,
    &"bytes={snes.dmaBytesThisFrame} not over budget"
  doAssert ms < StormWallMs,
    &"storm host time {ms}ms >= {StormWallMs}ms (budget not skipping work)"
  echo &"[test_dma_storm_budget] storm ok: bytes={snes.dmaBytesThisFrame} " &
    &"dmaStorm={snes.dmaStorm} ms={ms} transfers={snes.dmaTransfers}"

  # --- initHdma resets the byte counter; dmaStorm stays sticky ---
  snes.initHdma()
  doAssert snes.dmaBytesThisFrame == 0, "initHdma did not reset dmaBytesThisFrame"
  doAssert snes.dmaStorm, "initHdma must not clear dmaStorm (play loop owns that)"
  echo "[test_dma_storm_budget] initHdma reset ok (dmaStorm still sticky)"

when isMainModule:
  main()
