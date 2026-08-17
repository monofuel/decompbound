## Why this session TAS never leaves boot: compare cold boot vs loaded
## start.state under the play-faithful stepper (533 APU ticks) and
## policy.stepOneFrame (524, no top-up).

import
  std/[os, strformat],
  ../decompbound/[cpu, policy, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StartPath = "../decompbound_secret/sessions/20260816-183136/20260816-183136_start.state"
  SamplesPerFrame = 533
  BootFrames = 200

proc readRom(path: string): seq[uint8] =
  ## ROM bytes, strip optional 512-byte header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc stepPlay(snes: SnesBus, c: var Cpu) =
  ## play.nim / integration_emulator frame: 2 APU/line + top-up to 533.
  var smp = 0
  var l = 0
  while l < 262:
    snes.tickScanline(l)
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< policy.InstrPerLine:
      c.step(snes.bus)
      if c.stopped:
        break
    if l < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
      inc smp
    inc l
    if l >= 262:
      snes.initHdma()
      break
  while smp < SamplesPerFrame:
    discard snes.tickApu()
    inc smp

proc dump(tag: string, frame: int, snes: SnesBus, c: Cpu) =
  ## One-line PC / NMI / WAI / tg-ish WRAM peek.
  echo &"{tag} f={frame} PC={c.pbr:02X}:{c.pc:04X} nmi={snes.nmitimen:02X} " &
    &"wait={c.waiting} stop={c.stopped} nmiP={c.nmiPending} " &
    &"emu={c.emulation} P={c.p:02X} S={c.s:04X} A={c.a:04X}"

proc runCase(tag: string, loadState: bool, usePolicy: bool) =
  ## Boot `BootFrames` and print first NMI-on frame + last line.
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  if loadState:
    deserializeState(cast[seq[byte]](readFile(StartPath)), snes, c)
  echo &"=== {tag} after setup ==="
  dump(tag, -1, snes, c)
  var nmiAt = -1
  var left8141 = -1
  for f in 0 ..< BootFrames:
    if usePolicy:
      policy.stepOneFrame(snes, c, nil, render = false)
    else:
      stepPlay(snes, c)
    if left8141 < 0 and not (c.pbr == 0x00'u8 and c.pc == 0x8141'u16):
      left8141 = f
      dump(tag & " left8141", f, snes, c)
    if nmiAt < 0 and (snes.nmitimen and 0x80) != 0:
      nmiAt = f
      dump(tag & " nmiOn", f, snes, c)
    if c.stopped:
      dump(tag & " STP", f, snes, c)
      break
  dump(tag & " end", BootFrames - 1, snes, c)
  echo &"{tag} left8141={left8141} nmiOn={nmiAt} dma={snes.dmaTransfers}"

if not fileExists(RomPath):
  echo "no ROM"
  quit(1)

runCase("cold-play533", loadState = false, usePolicy = false)
runCase("cold-policy524", loadState = false, usePolicy = true)
if fileExists(StartPath):
  runCase("load-play533", loadState = true, usePolicy = false)
  runCase("load-policy524", loadState = true, usePolicy = true)
else:
  echo "no start state at ", StartPath
