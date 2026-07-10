## Referee lock for the navigation stack: collision formula ($C05F33 port),
## pixel-space nav.findPath, and the navTo Lua skill (waypoint following with
## diagonal slope input). Three legs from onett_start:
##   1. west clear — arrives fast.
##   2. crest via the winding 01/03 slope corridor — the terrain that defeats
##      reactive walkTo; locks pixel-space planning + diagonal input.
##   3. solid fence tile — honest BLOCKED report, no movement through walls.
## Legitimacy on all legs: per-frame |dpos| <= 8 px per axis (no teleports).
## Skips quietly when the user ROM / fixture state are absent.

import
  std/[os, strformat],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/touch_grass

const
  RomPath = "bin/Earthbound (U) [!].smc"
  FixtureState = "bin/states/llm/onett_start.state"
  SettleFrames = 30
  MaxStepDelta = 8
  ArriveThresh = 12
  Legs = [
    (name: "west_clear", tx: 0x0A48, ty: 0x0158, arrive: true, maxFrames: 3_000),
    (name: "crest_corridor", tx: 0x0A18, ty: 0x00C0, arrive: true, maxFrames: 10_000),
    (name: "solid_fence_blocked", tx: 0x0A60, ty: 0x0148, arrive: false, maxFrames: 1_000),
  ]

proc readRom(path: string): seq[uint8] =
  ## ROM bytes, stripping an optional 512-byte copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load + run a Lua chunk; assert on error.
  doAssert L.loadbuffer(src.cstring, src.len.cint, label.cstring) == lua53.OK,
    "lua load failed: " & label
  doAssert L.pcall(0, 0, 0) == lua53.OK, "lua pcall failed: " & label & ": " & $L.toString(-1)

proc playerPos(snes: SnesBus): (int, int) =
  ## Slot-24 world pixel position.
  let i = PlayerSlot * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc runLeg(rom: seq[uint8], skills: string,
    leg: tuple[name: string, tx, ty: int, arrive: bool, maxFrames: int]) =
  ## Run one navTo leg from a fresh fixture load; doAssert the outcome.
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FixtureState)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. SettleFrames:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)

  let ctx = policy.PolicyContext(snes: snes, frameImage: img)
  let L = lua53.newstate()
  doAssert L != nil
  defer: L.close()
  lua53.openlibs(L)
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, skills, "skills")
  loadChunk(L, &"""
_done = false
function update()
  if not navTo(0x{leg.tx:04X}, 0x{leg.ty:04X}) then _done = true end
end
""", "leg_policy")

  var (prevX, prevY) = playerPos(snes)
  var teleport = false
  var frames = 0
  for f in 0 ..< leg.maxFrames:
    ctx.frameCount = f
    doAssert policy.runPolicyFrame(L, ctx).len == 0, "policy error"
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let (px, py) = playerPos(snes)
    if abs(px - prevX) > MaxStepDelta or abs(py - prevY) > MaxStepDelta:
      teleport = true
    prevX = px
    prevY = py
    frames = f
    L.getglobal("_done".cstring)
    let done = L.toBool(-1)
    L.pop(1)
    if done:
      break
  let (ex, ey) = playerPos(snes)
  let dist = abs(leg.tx - ex) + abs(leg.ty - ey)
  doAssert not teleport, leg.name & ": illegitimate teleport (clipping?)"
  if leg.arrive:
    doAssert dist <= ArriveThresh + 4,
      &"{leg.name}: did not arrive (end=(0x{ex:04X},0x{ey:04X}) dist={dist} frames={frames})"
  else:
    doAssert dist > ArriveThresh,
      &"{leg.name}: reached a target inside a solid tile (clipped through collision)"

proc main() =
  ## Run all legs against the fixture; skip without ROM/state.
  if not fileExists(RomPath) or not fileExists(FixtureState):
    echo "[test_navto] skipped (ROM or fixture state absent)"
    return
  let rom = readRom(RomPath)
  # Seed skills straight from the source-of-truth consts (no bin/ dependency).
  let skills = EscapeMenuSkillLua & "\n\n" & WalkToSkillLua & "\n\n" &
    AdvanceDialogueSkillLua & "\n\n" & NavSkillLua
  for leg in Legs:
    runLeg(rom, skills, leg)
  echo "[test_navto] ok: west clear + crest corridor + solid-target BLOCKED, no teleports"

when isMainModule:
  main()
