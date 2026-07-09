## Emulator boot regression against the gold ROM (gitignored).
## Matches the known-good `make play` frame loop: scanline CPU budget +
## live APU ticks (2/line + top-up to 533). Without APU ticks the boot
## handshake never completes and NMI never enables — the old instr-only
## boot loop is not how play works at the known-good tip.

import
  std/[os, sets, strformat],
  decompbound/[cpu, snesbus]

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  ## Play path (src/tools/play.nim) — keep in lockstep with test_audio_tempo.
  InstrPerLine = 150
  SamplesPerFrame = 32000 div 60
  Scanlines = 262
  ApuTicksPerLine = 2
  ## NMI enables ~frame 81 with this loop; pad for machine variance.
  BootFrames = 400

proc readRomFile(filepath: string): seq[uint8] =
  ## Load ROM bytes, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc runPlayFrame(snes: SnesBus, cpu: var Cpu, uniquePcs: var HashSet[uint32]): int =
  ## One emulated frame matching play.nim: returns stereo samples produced
  ## including top-up (always SamplesPerFrame when fully stepped). Records
  ## PCs while the CPU is not parked in WAI so boot footprint stays honest.
  var smp = 0
  var l = 0
  while l < Scanlines:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      if not cpu.waiting:
        uniquePcs.incl((cpu.pbr.uint32 shl 16) or cpu.pc.uint32)
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
  result = smp

block bootToEngineIdle:
  ## Gold ROM must boot past anti-piracy, finish APU upload, enable NMI,
  ## and populate VRAM — same shape as a successful make play cold start.
  if not fileExists(GoldMasterRom):
    echo "[test_emulator] no gold ROM present; skipping boot regression"
  else:
    let snes = newSnesBus(readRomFile(GoldMasterRom))
    var cpu = snes.resetCpu()
    snes.initHdma()
    var uniquePcs = initHashSet[uint32]()
    var piracyPark = false
    var nmiEnabledFrame = -1
    var totalSamples = 0

    for frame in 0 ..< BootFrames:
      totalSamples += runPlayFrame(snes, cpu, uniquePcs)
      doAssert not cpu.stopped, "CPU hit STP during boot"
      if cpu.pbr == 0xC4'u8 and cpu.pc == 0x0BD2'u16:
        piracyPark = true
      if nmiEnabledFrame < 0 and (snes.nmitimen and 0x80) != 0:
        nmiEnabledFrame = frame

    doAssert not piracyPark, "anti-piracy check failed (SRAM regression)"
    doAssert nmiEnabledFrame >= 0,
      "NMI never enabled during boot (live APU handshake / play-loop regression?)"
    doAssert nmiEnabledFrame < 300,
      &"NMI enabled very late (frame {nmiEnabledFrame}); boot may have stalled"

    # Sample production must match play: full top-up every frame.
    doAssert totalSamples == BootFrames * SamplesPerFrame,
      &"sample count {totalSamples} != {BootFrames}*{SamplesPerFrame} (play coupling broken)"

    var apuWrites = 0
    for (address, _) in snes.mmioWrites:
      if address == 0x2140'u32:
        apuWrites += 1
    doAssert apuWrites > 15_000, "APU upload too small: " & $apuWrites
    doAssert snes.dmaTransfers > 5, "no graphics DMA: " & $snes.dmaTransfers
    var vramWords = 0
    for w in snes.vram:
      if w != 0:
        vramWords += 1
    doAssert vramWords > 200, "VRAM barely populated: " & $vramWords
    doAssert uniquePcs.len > 1_000, "boot footprint too small: " & $uniquePcs.len
    echo &"[test_emulator] boot ok: nmi@f{nmiEnabledFrame} apuW={apuWrites} " &
      &"dma={snes.dmaTransfers} vramNz={vramWords} pcs={uniquePcs.len} samples={totalSamples}"
