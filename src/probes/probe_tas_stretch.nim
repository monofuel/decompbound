## Find which TAS-frame : emu-frame ratio leaves the title screen.

import
  std/[os, strformat, tables],
  ../decompbound/[cpu, policy, replay, save_state, snesbus],
  ../tools/touch_grass

const
  RomPath = "bin/Earthbound (U) [!].smc"
  StatePath = "../decompbound_secret/sessions/20260816-183136/20260816-183136_start.state"
  TasPath = "../decompbound_secret/sessions/20260816-183136/20260816-183136.tas"
  TasFrames = 5000

proc readRom(path: string): seq[uint8] =
  ## ROM bytes minus copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc runStretch(stretch: int) =
  ## Replay `TasFrames` TAS frames, holding each for `stretch` emu frames.
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, c)
  let (_, deltas) = parseReplay(TasPath)
  let sched = deltasToTable(deltas)
  var joy: uint16 = 0
  var leftTitle = -1
  var lastPc = 0
  for tf in 0 .. TasFrames:
    if tf in sched:
      joy = sched[tf]
    for s in 1 .. stretch:
      snes.joy1 = joy
      policy.stepOneFrame(snes, c, nil, render = false)
    let (px, py) = replay.playerPos(snes)
    let tg = touchGrassPercent(snes)
    lastPc = (c.pbr.int shl 16) or c.pc.int
    if leftTitle < 0 and (px != 0 or py != 0 or tg > 0):
      leftTitle = tf
      echo &"  stretch={stretch} LEFT title at tas={tf} pos=({px:04X},{py:04X}) " &
        &"tg={tg} PC={c.pbr:02X}:{c.pc:04X} nmi={snes.nmitimen:02X}"
  let (px, py) = replay.playerPos(snes)
  echo &"stretch={stretch} end tas={TasFrames} pos=({px:04X},{py:04X}) " &
    &"tg={touchGrassPercent(snes)} PC={c.pbr:02X}:{c.pc:04X} leftTitle={leftTitle}"

echo "trying stretch 1..4 for first ", TasFrames, " TAS frames"
for st in 1 .. 4:
  runStretch(st)
