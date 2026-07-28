## Headless referee: hardware softReset preserves WRAM canary, reboots clean.
## Boot ROM ~120 frames, plant canary in WRAM scratch, softReset, assert canary
## immediately, then run until early boot activity (NMI on, not BRK-sink).
## Exit 0. No GUI/window.

import
  std/[os, strformat],
  decompbound/[cpu, snesbus]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  InstrPerLine = 150
  SamplesPerFrame = 32000 div 60
  Scanlines = 262
  ApuTicksPerLine = 2
  PreResetFrames = 120
  PostResetMaxFrames = 400
  ## WRAM scratch past low-mirror / game boot wipe zones; still bank $7E.
  CanaryAddr = 0x7E2000
  CanaryWord = 0xA5C3'u16

proc readRomFile(filepath: string): seq[uint8] =
  ## Load ROM bytes, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc runPlayFrame(snes: SnesBus, cpu: var Cpu) =
  ## One emulated frame matching play.nim CPU/APU budget (no render).
  var smp = 0
  var l = 0
  while l < Scanlines:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    for k in 0 ..< ApuTicksPerLine:
      discard snes.tickApu()
      smp += 1
    l += 1
    if l >= Scanlines:
      snes.initHdma()
      break
  while smp < SamplesPerFrame:
    discard snes.tickApu()
    smp += 1

proc plantCanary(snes: SnesBus) =
  ## Write a known word into WRAM that softReset must leave intact.
  snes.bus.mem[CanaryAddr] = (CanaryWord and 0xFF).uint8
  snes.bus.mem[CanaryAddr + 1] = ((CanaryWord shr 8) and 0xFF).uint8

proc readCanary(snes: SnesBus): uint16 =
  ## Read the canary word from WRAM.
  snes.bus.mem[CanaryAddr].uint16 or (snes.bus.mem[CanaryAddr + 1].uint16 shl 8)

proc main() =
  ## Boot, plant canary, softReset, assert canary + clean re-boot.
  if not fileExists(GoldMasterRom):
    echo "[test_soft_reset] SKIP (ROM absent)"
    return

  let snes = newSnesBus(readRomFile(GoldMasterRom))
  var cpu = snes.resetCpu()
  snes.initHdma()

  for f in 0 ..< PreResetFrames:
    runPlayFrame(snes, cpu)
    doAssert not cpu.stopped, &"CPU STP before reset at frame {f}"

  # Dirty MMIO / detector-visible state so reset has something real to clear.
  snes.nmitimen = 0x81
  snes.dmaStorm = true
  snes.dmaBytesThisFrame = 999_999
  snes.hdmaen = 0xFF
  snes.ppuRegs[0x00] = 0x0F

  plantCanary(snes)
  let canaryBefore = readCanary(snes)
  doAssert canaryBefore == CanaryWord, &"canary plant failed: {canaryBefore:04X}"

  cpu = snes.softReset()

  # Immediate post-reset asserts (before any frames).
  doAssert readCanary(snes) == CanaryWord,
    &"WRAM canary wiped by softReset: got {readCanary(snes):04X}"
  doAssert snes.nmitimen == 0,
    &"nmitimen not cleared: {snes.nmitimen:02X}"
  doAssert not snes.dmaStorm, "dmaStorm sticky after softReset"
  doAssert snes.dmaBytesThisFrame == 0, "dmaBytesThisFrame not zeroed"
  doAssert snes.hdmaen == 0, &"hdmaen not cleared: {snes.hdmaen:02X}"
  doAssert snes.ppuRegs[0x00] == 0, &"INIDISP not default: {snes.ppuRegs[0x00]:02X}"
  doAssert cpu.emulation, "CPU not in emulation mode after softReset"
  doAssert not (cpu.pbr == 0x00'u8 and cpu.pc == 0x5FFF'u16),
    "CPU landed on BRK-sink immediately after softReset"
  doAssert cpu.pbr == 0x00'u8,
    &"reset vector bank wrong: {cpu.pbr:02X}:{cpu.pc:04X}"
  doAssert snes.apu != nil and snes.apu.spc.pc == 0xFFC0'u16,
    &"APU not at IPL $FFC0: pc={snes.apu.spc.pc:04X}"

  # Game boot may wipe WRAM after reset; canary is only required to survive
  # the softReset call itself (asserted above, before any frames).
  var nmiEnabledFrame = -1
  for f in 0 ..< PostResetMaxFrames:
    runPlayFrame(snes, cpu)
    doAssert not cpu.stopped, &"CPU STP after reset at frame {f}"
    doAssert not (cpu.pbr == 0x00'u8 and cpu.pc == 0x5FFF'u16),
      &"BRK-sink 00:5FFF at post-reset frame {f}"
    if nmiEnabledFrame < 0 and (snes.nmitimen and 0x80) != 0:
      nmiEnabledFrame = f

  doAssert nmiEnabledFrame >= 0,
    "NMI never re-enabled after softReset (boot stall?)"
  doAssert nmiEnabledFrame < 300,
    &"NMI re-enabled very late (frame {nmiEnabledFrame})"
  doAssert (snes.nmitimen and 0x80) != 0,
    &"nmitimen bit7 clear at end (nmitimen={snes.nmitimen:02X})"

  echo &"[test_soft_reset] ok: pre={PreResetFrames}f canary={CanaryWord:04X} " &
    &"nmi@f{nmiEnabledFrame} PC={cpu.pbr:02X}:{cpu.pc:04X} " &
    &"nmitimen={snes.nmitimen:02X}"

when isMainModule:
  main()
