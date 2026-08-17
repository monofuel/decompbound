## Apply a DBTAS1 movie to a live machine. Cadence emu = one step per TAS
## frame. stretch > 1 is only for --legacy-stretch on window-loop files.

import
  std/[strformat, tables],
  ./[cpu, policy, replay, snesbus]

const
  PlayApuTopUp* = ReplayApuTicksPerFrame - 262 * 2

type
  ReplayFrameHook* = proc(snes: SnesBus, tasFrame: int) {.closure.}

proc stepReplayFrame*(snes: SnesBus, cpu: var Cpu) =
  ## One headless TAS frame: policy stepper + APU top-up to 533.
  policy.stepOneFrame(snes, cpu, nil, render = false)
  for i in 0 ..< PlayApuTopUp:
    discard snes.tickApu()

proc verifyChk*(snes: SnesBus, frame: int, chks: seq[ReplayCheckpoint]) =
  ## Abort on the first checkpoint mismatch at `frame`.
  for c in chks:
    if c.frame != frame:
      continue
    let (x, y) = playerPos(snes)
    let h = wramHash(snes)
    if x != c.x or y != c.y or h != c.wramHash:
      raise newException(ValueError,
        &"TAS desync at frame {frame}: " &
        &"got pos=({x:04x},{y:04x}) hash=0x{h:08x} " &
        &"want pos=({c.x:04x},{c.y:04x}) hash=0x{c.wramHash:08x}")

proc applyTas*(snes: SnesBus, cpu: var Cpu, deltas: seq[ReplayDelta],
    maxTasFrame: int, stretch = 1, checkpoints: seq[ReplayCheckpoint] = @[],
    onFrame: ReplayFrameHook = nil): int =
  ## Feed joy1 from `deltas` for TAS frames 0..maxTasFrame inclusive.
  ## Each TAS frame is held for `stretch` emu frames. Returns emu steps.
  if stretch < 1:
    raise newException(ValueError, "stretch must be >= 1")
  if maxTasFrame < 0:
    return
  let sched = deltasToTable(deltas)
  var joy = 0'u16
  for tf in 0 .. maxTasFrame:
    if tf in sched:
      joy = sched[tf]
    for s in 1 .. stretch:
      snes.joy1 = joy
      stepReplayFrame(snes, cpu)
      inc result
      if cpu.stopped:
        return
    if stretch == 1:
      verifyChk(snes, tf, checkpoints)
    if onFrame != nil:
      onFrame(snes, tf)
