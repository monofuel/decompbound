## Referee: crash3 reverse-MDMA wipe derail must not fire with the guard on.
## Load earthbound_20260726-212944.png, apply TAS joy deltas aligned at
## segframe 4500, run 200 frames. Assert no BRK-sink, $0020 stays ROM-class,
## nmitimen bit7 restored by window end, no dmaStorm.
## SKIP (exit 0) if PNG/TAS/ROM absent. Failure-mode proof:
##   nim r -d:dmaWramToAAllow tests/test_crash3_repro.nim  (must FAIL without guard)

import
  std/[options, os, strformat],
  decompbound/[cpu, png_state, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  PngNear6 = "/home/monofuel/Pictures/Screenshots/earthbound_20260726-212944.png"
  SessionTas = "bin/sessions/20260726-212828/20260726-212832.tas"
  AlignFrame = 4500
  RunFrames = 200
  InstrPerLine = 150
  SamplesPerFrame = 32000 div 60
  Scanlines = 262
  ApuTicksPerLine = 2

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc wram16(snes: SnesBus, off: int): uint16 =
  ## Little-endian WRAM word at bank $7E.
  snes.bus.mem[0x7E0000 + off].uint16 or
    (snes.bus.mem[0x7E0001 + off].uint16 shl 8)

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

proc main() =
  ## 212944 + TAS@4500 window; guard must keep the NMI vector and CPU alive.
  if not fileExists(RomPath):
    echo "[test_crash3_repro] SKIP (ROM absent)"
    return
  if not fileExists(PngNear6):
    echo "[test_crash3_repro] SKIP (PNG absent)"
    return
  if not fileExists(SessionTas):
    echo "[test_crash3_repro] SKIP (TAS absent)"
    return

  let (_, deltas) = parseReplay(SessionTas)
  let snes = newSnesBus(readRom(RomPath))
  var cpu = snes.resetCpu()
  let ex = extractState(cast[seq[uint8]](readFile(PngNear6)))
  doAssert ex.isSome, &"PNG has no ebSt chunk: {PngNear6}"
  deserializeState(ex.get, snes, cpu)

  let vec0 = wram16(snes, 0x0020)
  doAssert vec0 >= 0x8000'u16,
    &"fixture $0020={vec0:04X} not ROM-class (bad PNG?)"

  var sawNmiMasked = false
  for f in 0 ..< RunFrames:
    snes.joy1 = joyAtFrame(deltas, AlignFrame + f)
    runPlayFrame(snes, cpu)
    doAssert not (cpu.pbr == 0x00'u8 and cpu.pc == 0x5FFF'u16),
      &"BRK-sink 00:5FFF at frame {f} PC={cpu.pbr:02X}:{cpu.pc:04X} " &
      &"S={cpu.s:04X} $0020={wram16(snes, 0x0020):04X}"
    let vec = wram16(snes, 0x0020)
    doAssert vec >= 0x8000'u16,
      &"$0020 wiped to {vec:04X} at frame {f} PC={cpu.pbr:02X}:{cpu.pc:04X}"
    doAssert not snes.dmaStorm,
      &"dmaStorm at frame {f} PC={cpu.pbr:02X}:{cpu.pc:04X}"
    if (snes.nmitimen and 0x80) == 0:
      sawNmiMasked = true

  doAssert (snes.nmitimen and 0x80) != 0,
    &"nmitimen bit7 not restored by window end " &
    &"(nmitimen={snes.nmitimen:02X} sawMasked={sawNmiMasked})"
  echo &"[test_crash3_repro] ok: {RunFrames}f align={AlignFrame} " &
    &"PC={cpu.pbr:02X}:{cpu.pc:04X} $0020={wram16(snes, 0x0020):04X} " &
    &"nmitimen={snes.nmitimen:02X} sawNmiMasked={sawNmiMasked} " &
    &"dmaWramToAFired={snes.dmaWramToA or snes.dmaWramToASize != 0}"

when isMainModule:
  main()
