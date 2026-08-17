## Start-state + TAS joy deltas must reproduce the later machine.

import
  std/[os, strformat, strutils],
  decompbound/[cpu, policy, replay, replay_run, save_state, snesbus]

type
  EndSnap = object
    pos: tuple[x: uint16, y: uint16]
    wram: uint32
    blob: seq[byte]
    nmitimen: uint8
    pc: uint16

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  BedroomState = "bin/states/llm/bedroom.state"
  BootFrames = 80
  ColdMovieFrames = 80
  BedroomMovieFrames = 40
  JoyRight = policy.BtnRight

proc stepFrame(snes: SnesBus, cpu: var Cpu) =
  ## One headless TAS frame (same stepper as play/replay).
  stepReplayFrame(snes, cpu)

proc bootQuiet(snes: SnesBus, cpu: var Cpu, frames: int) =
  ## Advance `frames` with joy1 held at 0 so NMI can enable.
  snes.joy1 = 0
  for _ in 0 ..< frames:
    stepFrame(snes, cpu)

proc recordHoldRight(snes: SnesBus, cpu: var Cpu, frames: int,
    releaseLast = false): seq[ReplayDelta] =
  ## Record `frames` of TAS: frame 0 idle, then Right. Deltas only on change.
  result = @[]
  var lastJoy = 0xFFFF'u16
  for frame in 0 ..< frames:
    var joy = if frame == 0: 0'u16 else: JoyRight
    if releaseLast and frame == frames - 1:
      joy = 0'u16
    if joy != lastJoy:
      result.add(ReplayDelta(frame: frame, joy1: joy))
      lastJoy = joy
    snes.joy1 = joy
    stepFrame(snes, cpu)

proc replayMovie(snes: SnesBus, cpu: var Cpu, deltas: seq[ReplayDelta],
    frames: int) =
  ## Replay held joy1 from `deltas` for `frames` steps via applyTas.
  if frames <= 0:
    return
  discard applyTas(snes, cpu, deltas, frames - 1)

proc takeSnap(snes: SnesBus, cpu: Cpu): EndSnap =
  ## Capture pos, WRAM hash, serialize blob, and CPU/NMI identity fields.
  EndSnap(
    pos: playerPos(snes),
    wram: wramHash(snes),
    blob: serializeState(snes, cpu),
    nmitimen: snes.nmitimen,
    pc: cpu.pc
  )

proc assertIdentity(a, b: EndSnap, label: string) =
  ## Require matching pos + WRAM hash; prefer full serialize, else NMI/PC.
  doAssert a.pos == b.pos,
    &"{label} pos ({a.pos.x:04X},{a.pos.y:04X}) vs ({b.pos.x:04X},{b.pos.y:04X})"
  doAssert a.wram == b.wram,
    &"{label} wramHash 0x{a.wram:08X} vs 0x{b.wram:08X}"
  doAssert a.blob == b.blob,
    &"{label} serialize mismatch (nmitimen 0x{a.nmitimen:02X}/0x{b.nmitimen:02X} pc 0x{a.pc:04X}/0x{b.pc:04X})"

proc runIdentity(snes: SnesBus, cpu: var Cpu, frames: int, label: string,
    releaseLast = false) =
  ## Record a hold-Right movie from the current seat, restore start, replay it.
  let startBlob = serializeState(snes, cpu)
  deserializeState(startBlob, snes, cpu)
  let deltas = recordHoldRight(snes, cpu, frames, releaseLast = releaseLast)
  let snapA = takeSnap(snes, cpu)
  deserializeState(startBlob, snes, cpu)
  replayMovie(snes, cpu, deltas, frames)
  let snapB = takeSnap(snes, cpu)
  assertIdentity(snapA, snapB, label)
  echo &"[e2e_tas_identity] {label} ok pos=({snapA.pos.x:04X},{snapA.pos.y:04X}) " &
    &"hash=0x{snapA.wram:08X} serializeMatch={snapA.blob == snapB.blob}"

block coldBootTasIdentity:
  if not fileExists(GoldMasterRom):
    echo "[e2e_tas_identity] no gold ROM present; skipping cold-boot"
  else:
    let snes = newSnesBus(policy.readRomFile(GoldMasterRom))
    var cpu = snes.resetCpu()
    snes.initHdma()
    bootQuiet(snes, cpu, BootFrames)
    runIdentity(snes, cpu, ColdMovieFrames, "cold-boot", releaseLast = true)

block bedroomTasIdentity:
  if not fileExists(GoldMasterRom):
    echo "[e2e_tas_identity] no gold ROM present; skipping bedroom"
  elif not fileExists(BedroomState):
    echo "[e2e_tas_identity] no bedroom.state; skipping bedroom"
  else:
    let snes = newSnesBus(policy.readRomFile(GoldMasterRom))
    var cpu = snes.resetCpu()
    snes.initHdma()
    deserializeState(cast[seq[byte]](readFile(BedroomState)), snes, cpu)
    runIdentity(snes, cpu, BedroomMovieFrames, "bedroom")

block cadenceAndChk:
  let header = ReplayHeader(
    magic: ReplayMagic,
    romHash: 1,
    startStateRef: "x",
    cadence: ReplayCadenceEmu,
    apuTicks: ReplayApuTicksPerFrame
  )
  let text = serializeReplay(header, @[ReplayDelta(frame: 0, joy1: 0)])
  doAssert "cadence emu" in text
  doAssert "apu_ticks 533" in text
  let (h, _) = parseReplayString(text)
  doAssert not isLegacyReplay(h)
  doAssert h.apuTicks == ReplayApuTicksPerFrame
  let legacy = parseReplayString("DBTAS1\nrom_hash 0x1\nstart_state x\n0 0000\n")
  doAssert isLegacyReplay(legacy.header)

block chkFailLoud:
  if not fileExists(GoldMasterRom):
    echo "[e2e_tas_identity] no gold ROM; skip chkFailLoud"
  else:
    let snes = newSnesBus(policy.readRomFile(GoldMasterRom))
    var cpu = snes.resetCpu()
    snes.initHdma()
    bootQuiet(snes, cpu, BootFrames)
    let bad = @[ReplayCheckpoint(frame: 0, x: 0xFFFF, y: 0xFFFF, wramHash: 1)]
    var raised = false
    try:
      discard applyTas(snes, cpu,
        @[ReplayDelta(frame: 0, joy1: 0)], 0, stretch = 1, checkpoints = bad)
    except ValueError:
      raised = true
    doAssert raised, "applyTas must abort on checkpoint mismatch"
