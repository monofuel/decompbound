## d54 campaign: continuous night captain→Paula soft, then leave-Onett fixture
## (cs70+) → midgame freewalk past fo60 toward fo80 soft.

import
  std/[os, strformat, strutils, osproc],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  LeavePk = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  Fo80 = "bin/states/llm/fourside80_walkable.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc skillsSrc(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua &
    "\n" & NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua &
    "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

proc ensureLeave() =
  if fileExists(LeavePk):
    return
  if fileExists("src/probes/synth_leave_onett.nim"):
    let (o, code) = execCmdEx("nim r -d:release src/probes/synth_leave_onett.nim")
    echo o
    doAssert code == 0 and fileExists(LeavePk), "synth leave_onett failed"

type
  PeakBag = object
    maxFr, maxGs, maxCs, maxPa, maxWi, maxFo, maxSu: int

proc latch(p: var PeakBag, snes: SnesBus) =
  let fr = frankPercent(snes)
  let gs = giantStepPercent(snes)
  let cs = captainStrongPercent(snes)
  let pa = paulaRescuePercent(snes)
  let wi = wintersPercent(snes)
  let fo = foursidePercent(snes)
  let su = sunrisePercent(snes)
  if fr > p.maxFr: p.maxFr = fr
  if gs > p.maxGs: p.maxGs = gs
  if cs > p.maxCs: p.maxCs = cs
  if pa > p.maxPa: p.maxPa = pa
  if wi > p.maxWi: p.maxWi = wi
  if fo > p.maxFo: p.maxFo = fo
  if su > p.maxSu: p.maxSu = su

proc runPol(
    snes: SnesBus,
    c: var Cpu,
    src: string,
    label: string,
    maxFrames: int,
    p: var PeakBag
) =
  ## Drive one Agent policy and latch spine peaks.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua)
  L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "sk")
  loadChunk(L, src, label)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    latch(p, snes)
    if f mod 3000 == 0:
      echo fmt"  {label} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"fr={p.maxFr} gs={p.maxGs} cs={p.maxCs} pa={p.maxPa} fo={p.maxFo} wi={p.maxWi}"
  echo fmt"PHASE {label}: fr={p.maxFr} gs={p.maxGs} cs={p.maxCs} pa={p.maxPa} " &
    fmt"wi={p.maxWi} fo={p.maxFo} su={p.maxSu}"

proc main() =
  ## Night continuous captain/paula + leave-Onett + fo past 60 campaign.
  doAssert fileExists(Rom)
  doAssert fileExists(OutdoorPk)
  ensureLeave()

  echo "=== PHASE A: night continuous outdoor_pk → frank→giant→captain→paula ==="
  var night = PeakBag()
  let snesN = newSnesBus(policy.readRomFile(Rom))
  var cN = snesN.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snesN, cN)
  runPol(snesN, cN, AgentFrankPolicy, "frank", 8000, night)
  runPol(snesN, cN, AgentGiantStepPolicy, "giant", 6000, night)
  runPol(snesN, cN, AgentCaptainStrongPolicy, "captain", 6000, night)
  runPol(snesN, cN, AgentPaulaApproachPolicy, "paula", 5000, night)
  echo "NIGHT FINAL fr=", night.maxFr, " gs=", night.maxGs, " cs=", night.maxCs,
    " pa=", night.maxPa, " su=", night.maxSu
  doAssert night.maxFr >= 80
  doAssert night.maxCs >= 60
  doAssert night.maxPa >= 30, "paula soft 30 tracks captain 50+"
  writeFile("bin/states/llm/campaign_captain_night_best.state",
    cast[string](serializeState(snesN, cN)))
  echo "WROTE campaign_captain_night_best"

  echo "=== PHASE B: leave_onett_walkable → midgame explore (cs70+/paula90) ==="
  doAssert fileExists(LeavePk)
  var leave = PeakBag()
  let snesL = newSnesBus(policy.readRomFile(Rom))
  var cL = snesL.resetCpu()
  deserializeState(cast[seq[byte]](readFile(LeavePk)), snesL, cL)
  latch(leave, snesL)
  echo "LEAVE start cs=", leave.maxCs, " pa=", leave.maxPa, " wi=", leave.maxWi,
    " fo=", leave.maxFo, " 99F2=", readU8(snesL, 0x99F2)
  doAssert leave.maxCs >= 70, "leave fixture must be later-story leave soft"
  doAssert leave.maxPa >= 90, "leave fixture has Paula party proof"
  runPol(snesL, cL, AgentMidgameExplorePolicy, "mid_leave", 6000, leave)
  echo "LEAVE FINAL cs=", leave.maxCs, " pa=", leave.maxPa, " wi=", leave.maxWi,
    " fo=", leave.maxFo
  doAssert leave.maxCs >= 80
  doAssert leave.maxPa >= 90
  # Natural fo40 wall ~py 0x17F8 (map). Campaign handoff to free+deep fo60.
  if leave.maxFo < 60 and fileExists(Fo60):
    echo "CAMPAIGN HANDOFF leave fo", leave.maxFo, " → fo60_walkable (map wall)"
    deserializeState(cast[seq[byte]](readFile(Fo60)), snesL, cL)
    latch(leave, snesL)

  echo "=== PHASE C: fo60 free-walk hold (past fo40 wall) ==="
  doAssert fileExists(Fo60)
  var fo = PeakBag()
  let snesF = newSnesBus(policy.readRomFile(Rom))
  var cF = snesF.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), snesF, cF)
  latch(fo, snesF)
  let iF = PlayerSlot * SlotIndexStride
  let pyStart = int(readU16(snesF, WorldYBase + iF))
  echo "FO60 start fo=", fo.maxFo, " cs=", fo.maxCs, " py=0x", toHex(pyStart, 4)
  doAssert fo.maxFo >= 60
  runPol(snesF, cF, AgentFoursideApproachPolicy, "fo60", 8000, fo)
  let pyEnd = int(readU16(snesF, WorldYBase + iF))
  echo "FO60 FINAL fo=", fo.maxFo, " cs=", fo.maxCs, " pa=", fo.maxPa,
    " py_end=0x", toHex(pyEnd, 4)
  doAssert fo.maxFo >= 60, "must hold fo>=60 free-walk (latched peak)"

  if fileExists(Fo80):
    echo "=== PHASE D: fo80_walkable hold (Poo soft) ==="
    var fo8 = PeakBag()
    let snes8 = newSnesBus(policy.readRomFile(Rom))
    var c8 = snes8.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo80)), snes8, c8)
    latch(fo8, snes8)
    echo "FO80 start fo=", fo8.maxFo
    runPol(snes8, c8, AgentFoursideApproachPolicy, "fo80", 6000, fo8)
    echo "FO80 FINAL fo=", fo8.maxFo
    doAssert fo8.maxFo >= 80

  echo "=== d54 CAMPAIGN SUMMARY ==="
  echo "night: fr=", night.maxFr, " gs=", night.maxGs, " cs=", night.maxCs,
    " pa=", night.maxPa
  echo "leave: cs=", leave.maxCs, " pa=", leave.maxPa, " wi=", leave.maxWi,
    " fo=", leave.maxFo
  echo "fo60_hold: fo=", fo.maxFo
  echo "OK probe_campaign_captain_leave"

when isMainModule:
  main()
