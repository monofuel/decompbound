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
    var reachedPark = false

    for executed in 0..<BootInstructions:
      if (snes.nmitimen and 0x80) != 0 and
         executed mod InstructionsPerFrame == 0 and executed > 0:
        cpu.nmiPending = true
      if not cpu.waiting:
        uniquePcs.incl (cpu.pbr.uint32 shl 16) or cpu.pc.uint32
      # The engine idle: main thread parks on BRA -2 at $C40BD2 while the
      # NMI handler runs the game.
      if cpu.pbr == 0xC4 and cpu.pc == 0x0BD2:
        reachedPark = true
      cpu.step(snes.bus)
      doAssert not cpu.stopped, "CPU hit STP during boot"

    # Boot must complete the sound driver upload and enable NMI.
    doAssert (snes.nmitimen and 0x80) != 0, "NMI never enabled during boot"
    doAssert reachedPark, "boot never reached the engine idle at $C40BD2"
    # The sound driver upload is ~17.8KB of port writes.
    var apuWrites = 0
    for (address, _) in snes.mmioWrites:
      if address == 0x2140:
        apuWrites += 1
    doAssert apuWrites > 15_000, "APU upload too small: " & $apuWrites
    # A real boot executes a wide code footprint.
    doAssert uniquePcs.len > 1_000, "boot footprint too small: " & $uniquePcs.len
