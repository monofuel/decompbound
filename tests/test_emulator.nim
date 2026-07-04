## Emulator boot regression: the real Earthbound must boot to its engine
## idle state on the CPU core + SNES bus. Pins the boot depth so bus or
## core regressions show up as "boot got shallower".
## Only runs where the (gitignored, copyrighted) gold ROM exists.

import
  std/[os, sets],
  decompbound/[cpu, snesbus]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  BootInstructions = 1_500_000
  InstructionsPerFrame = 8000

block bootToEngineIdle:
  if fileExists(GoldMasterRom):
    let romStr = readFile(GoldMasterRom)
    var rom = newSeq[uint8](romStr.len)
    for i in 0..<romStr.len:
      rom[i] = romStr[i].uint8

    let snes = newSnesBus(rom)
    var cpu = snes.resetCpu()
    var uniquePcs = initHashSet[uint32]()
    var piracyPark = false

    for executed in 0..<BootInstructions:
      if (snes.nmitimen and 0x80) != 0 and
         executed mod InstructionsPerFrame == 0 and executed > 0:
        cpu.nmiPending = true
      if not cpu.waiting:
        uniquePcs.incl (cpu.pbr.uint32 shl 16) or cpu.pc.uint32
      # $C40BD2 is the anti-piracy screen's park loop: reaching it means
      # the SRAM check failed and the game gave up.
      if cpu.pbr == 0xC4 and cpu.pc == 0x0BD2:
        piracyPark = true
      cpu.step(snes.bus)
      doAssert not cpu.stopped, "CPU hit STP during boot"

    # A healthy boot: SRAM satisfies the anti-piracy check, the sound
    # driver uploads, NMI is enabled, and graphics flow through DMA.
    doAssert not piracyPark, "anti-piracy check failed (SRAM regression)"
    doAssert (snes.nmitimen and 0x80) != 0, "NMI never enabled during boot"
    var apuWrites = 0
    for (address, _) in snes.mmioWrites:
      if address == 0x2140:
        apuWrites += 1
    doAssert apuWrites > 15_000, "APU upload too small: " & $apuWrites
    doAssert snes.dmaTransfers > 5, "no graphics DMA: " & $snes.dmaTransfers
    var vramWords = 0
    for w in snes.vram:
      if w != 0:
        vramWords += 1
    doAssert vramWords > 1_000, "VRAM barely populated: " & $vramWords
    doAssert uniquePcs.len > 1_000, "boot footprint too small: " & $uniquePcs.len
