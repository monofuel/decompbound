## d73: past captain leave — Twoson corridor freeplay (peaceful_rest / lilliput).
## From leave_onett_walkable (Paula+Jeff) drive AgentMidgame; capture deltas.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_onett_walkable.state"
  LeaveMap = "bin/states/llm/leave_day1_map.state"
  Mid = "bin/states/llm/midgame_approach.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & IntentNavSkillLua

proc grade(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"cs={captainStrongPercent(snes)} pr={peacefulRestPercent(snes)} " &
    fmt"pa={paulaRescuePercent(snes)} li={lilliputStepsPercent(snes)} " &
    fmt"wi={wintersPercent(snes)} fo={foursidePercent(snes)}"
  echo "  ", checkpointSpineLine(snes)

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; frames: int; label: string) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, skills(), "sk")
  loadChunk(L, pol, label)
  let i = PlayerSlot * SlotIndexStride
  var maxPr = peacefulRestPercent(snes)
  var maxLi = lilliputStepsPercent(snes)
  var maxFo = foursidePercent(snes)
  var maxPa = paulaRescuePercent(snes)
  var minX = readU16(snes, WorldXBase+i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase+i)
  var maxY = minY
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    applyLaterStoryLeaveSoft(snes)
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    let pr = peacefulRestPercent(snes)
    let li = lilliputStepsPercent(snes)
    let fo = foursidePercent(snes)
    let pa = paulaRescuePercent(snes)
    if pr > maxPr: maxPr = pr
    if li > maxLi: maxLi = li
    if fo > maxFo: maxFo = fo
    if pa > maxPa: maxPa = pa
    if f mod 2500 == 0:
      echo fmt"  {label} f={f} pos=(0x{px:04X},0x{py:04X}) pr={pr} li={li} fo={fo} pa={pa}"
  echo fmt"FINAL {label} maxPr={maxPr} maxLi={maxLi} maxFo={maxFo} maxPa={maxPa} " &
    fmt"bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} span={(maxX-minX)+(maxY-minY)}"

proc main() =
  doAssert fileExists(Rom)
  echo "=== d73 Twoson corridor freeplay ==="
  if fileExists(Leave):
    echo "--- leave_onett_walkable AgentMidgame ---"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Leave)), snes, cpu)
    applyLaterStoryLeaveSoft(snes)
    grade(snes, "start_leave")
    runPol(snes, cpu, AgentMidgameExplorePolicy, 10000, "MidLeave")
    grade(snes, "end_leave")
  if fileExists(LeaveMap):
    echo "--- leave_day1_map AgentPaula (Ness-only) ---"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(LeaveMap)), snes, cpu)
    applyLaterStoryLeaveSoft(snes)
    grade(snes, "start_solo")
    runPol(snes, cpu, AgentPaulaApproachPolicy, 8000, "PaulaSolo")
    grade(snes, "end_solo")
  if fileExists(Mid):
    echo "--- midgame_approach AgentMidgame (fo wall) ---"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Mid)), snes, cpu)
    applyLaterStoryLeaveSoft(snes)
    grade(snes, "start_mid")
    runPol(snes, cpu, AgentMidgameExplorePolicy, 8000, "MidWall")
    grade(snes, "end_mid")
  echo "OK probe_d73_twoson_spine"

when isMainModule:
  main()
