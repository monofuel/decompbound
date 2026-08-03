## Referee locks for the Tenda Village softlock class (2026-07-26).
## (1) Hang F12 signature: BRK sink at 00:5FFF with NMI masked.
## (2) Drop PNG health: 600 idle frames stay live with NMI on and APU samples.
## (3) $7C WRAM-spray hang F12: MDMA budget caps the death spiral (<200ms/frame,
##     dmaStorm true). Paths under Pictures; PNGs are never committed.
## SKIP cleanly (exit 0) when a fixture is absent.

import
  std/[monotimes, os, options, strformat, times],
  decompbound/[cpu, png_state, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  HangPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-202823.png"
  DropPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260725-190533.png"
  SprayHangPng = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-210013.png"
  InstrPerLine = 150
  SamplesPerFrame = 32000 div 60
  DropFrames = 600
  SprayFrames = 3
  SprayWallMs = 200

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc runPlayFrame(snes: SnesBus, cpu: var Cpu): tuple[peakAbs, nonzero: int] =
  ## One play-faithful frame; returns APU sample energy this frame.
  var smp = 0
  var peakAbs = 0
  var nonzero = 0
  var l = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    for k in 0 ..< 2:
      let (left, right) = snes.tickApu()
      let la = abs(left.int)
      let ra = abs(right.int)
      if la > peakAbs: peakAbs = la
      if ra > peakAbs: peakAbs = ra
      if left != 0 or right != 0: inc nonzero
      inc smp
    l += 1
    if l >= 262:
      snes.initHdma()
      break
  while smp < SamplesPerFrame:
    let (left, right) = snes.tickApu()
    let la = abs(left.int)
    let ra = abs(right.int)
    if la > peakAbs: peakAbs = la
    if ra > peakAbs: peakAbs = ra
    if left != 0 or right != 0: inc nonzero
    inc smp
  (peakAbs, nonzero)

proc loadPng(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  ## ROM + extractState from an ebSt PNG.
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  let ex = extractState(cast[seq[uint8]](readFile(path)))
  doAssert ex.isSome, &"PNG has no ebSt chunk: {path}"
  deserializeState(ex.get, snes, cpu)
  (snes, cpu)

proc main() =
  ## Signature lock + drop-health; each section skips if its fixture is gone.
  if not fileExists(RomPath):
    echo "[test_tenda_brk_sink_signature] SKIP (ROM absent)"
    return

  # --- (c) Hang F12 signature ---
  if not fileExists(HangPng):
    echo "[test_tenda_brk_sink_signature] SKIP hang (PNG absent)"
  else:
    let loaded = loadPng(HangPng)
    let snes = loaded.snes
    let cpu = loaded.cpu
    doAssert cpu.pbr == 0x00'u8, &"hang pbr={cpu.pbr:02X} want 00"
    doAssert cpu.pc == 0x5FFF'u16, &"hang pc={cpu.pc:04X} want 5FFF"
    doAssert (snes.nmitimen and 0x80) == 0,
      &"hang nmitimen={snes.nmitimen:02X} expected bit7 clear"
    echo &"[test_tenda_brk_sink_signature] hang ok: " &
      &"PC={cpu.pbr:02X}:{cpu.pc:04X} nmitimen={snes.nmitimen:02X}"

  # --- (d) Drop PNG health ---
  if not fileExists(DropPng):
    echo "[test_tenda_brk_sink_signature] SKIP drop (PNG absent)"
  else:
    let loaded = loadPng(DropPng)
    let snes = loaded.snes
    var cpu = loaded.cpu
    var peakAll = 0
    var nonzeroAll = 0
    for f in 0 ..< DropFrames:
      let (peak, nz) = runPlayFrame(snes, cpu)
      if peak > peakAll: peakAll = peak
      nonzeroAll += nz
      doAssert not (cpu.pbr == 0x00'u8 and cpu.pc == 0x5FFF'u16),
        &"drop: BRK-sink at frame {f}"
    doAssert (snes.nmitimen and 0x80) != 0,
      &"drop: NMI still masked after {DropFrames}f (nmitimen={snes.nmitimen:02X})"
    doAssert nonzeroAll > 0 and peakAll > 0,
      &"drop: APU silent after {DropFrames}f (nonzero={nonzeroAll} peak={peakAll})"
    echo &"[test_tenda_brk_sink_signature] drop ok: " &
      &"PC={cpu.pbr:02X}:{cpu.pc:04X} nmitimen={snes.nmitimen:02X} " &
      &"peakAbs={peakAll} nonzeroSamples={nonzeroAll}"

  # --- (e) $7C spray hang: DMA budget caps the 515ms death spiral ---
  if not fileExists(SprayHangPng):
    echo "[test_tenda_brk_sink_signature] SKIP spray hang (PNG absent)"
  else:
    let loaded = loadPng(SprayHangPng)
    let snes = loaded.snes
    var cpu = loaded.cpu
    for f in 0 ..< SprayFrames:
      let t0 = getMonoTime()
      discard runPlayFrame(snes, cpu)
      let ms = (getMonoTime() - t0).inMilliseconds
      doAssert ms < SprayWallMs,
        &"spray hang frame {f}: {ms}ms >= {SprayWallMs}ms (death spiral uncapped)"
      doAssert snes.dmaStorm,
        &"spray hang frame {f}: dmaStorm not set (budget never tripped)"
      # Play loop clears the flag after logging; re-arm for the next frame.
      snes.dmaStorm = false
    echo &"[test_tenda_brk_sink_signature] spray hang ok: " &
      &"{SprayFrames} frames <{SprayWallMs}ms with dmaStorm " &
      &"PC={cpu.pbr:02X}:{cpu.pc:04X}"

when isMainModule:
  main()
