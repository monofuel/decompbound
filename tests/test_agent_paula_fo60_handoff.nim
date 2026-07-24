## d67 product: after Paula join, fo40 wall cannot freewalk — campaign handoff
## seats deep free+Paula fixture and AgentFourside holds fo60.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_onett_walkable.state"
  FoFromPaula = "bin/states/llm/fourside60_from_paula.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills.
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind landmarkTarget(name).
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; maxFrames: int):
    tuple[fo, pa, wi, cs, maxPy, minPy: int] =
  ## Run shipped Agent policy; return peaks and y extent.
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
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "skills")
  loadChunk(L, pol, "pol")
  let i = PlayerSlot * SlotIndexStride
  result.fo = foursidePercent(snes)
  result.pa = paulaRescuePercent(snes)
  result.wi = wintersPercent(snes)
  result.cs = captainStrongPercent(snes)
  result.maxPy = readU16(snes, WorldYBase + i)
  result.minPy = result.maxPy
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let fo = foursidePercent(snes)
    let pa = paulaRescuePercent(snes)
    let wi = wintersPercent(snes)
    let cs = captainStrongPercent(snes)
    let py = readU16(snes, WorldYBase + i)
    if fo > result.fo: result.fo = fo
    if pa > result.pa: result.pa = pa
    if wi > result.wi: result.wi = wi
    if cs > result.cs: result.cs = cs
    if py > result.maxPy: result.maxPy = py
    if py < result.minPy: result.minPy = py
    if result.fo >= 60 and f >= 400:
      break

proc ensurePaulaFo60() =
  ## Synth Paula-join fo60 deep seat if missing.
  if fileExists(FoFromPaula):
    return
  let (o, code) = execCmdEx("nim r -d:release src/tools/synth_fourside60_from_paula.nim")
  echo o
  doAssert code == 0 and fileExists(FoFromPaula), "synth_fourside60_from_paula failed"

proc main() =
  ## leave fo40 wall → campaign deep seat → AgentFourside holds fo60 with Paula.
  doAssert fileExists(Rom)
  doAssert fileExists(Leave)
  ensurePaulaFo60()

  # Leg A: leave_onett freewalk cannot pass wall (referee).
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Leave)), snes, cpu)
    doAssert partyHasChar(snes, PartyCharPaula)
    doAssert wintersPercent(snes) >= 50
    let startFo = foursidePercent(snes)
    echo "A leave start fo=", startFo, " pa=", paulaRescuePercent(snes),
      " wi=", wintersPercent(snes)
    doAssert startFo >= 40 and startFo < 60
    let m = runPol(snes, cpu, AgentMidgameExplorePolicy, 5000)
    echo "A mid explore maxFo=", m.fo, " maxPy=0x", toHex(m.maxPy, 4),
      " minPy=0x", toHex(m.minPy, 4)
    doAssert m.fo < 60, "natural freewalk must not reach fo60 (got " & $m.fo & ")"
    doAssert m.maxPy < 0x1A00, "must not freewalk past wall to py 0x1A00"

  # Leg B: campaign handoff seat (Paula continuity) grades fo60.
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FoFromPaula)), snes, cpu)
    let fo = foursidePercent(snes)
    let pa = paulaRescuePercent(snes)
    let wi = wintersPercent(snes)
    echo "B seat fo=", fo, " pa=", pa, " wi=", wi,
      " party Paula=", partyHasChar(snes, PartyCharPaula),
      " Jeff=", partyHasChar(snes, PartyCharJeff)
    doAssert fo >= 60, "Paula fo60 seat must grade fo>=60"
    doAssert partyHasChar(snes, PartyCharPaula), "handoff must keep Paula"
    doAssert partyHasChar(snes, PartyCharJeff), "handoff must keep Jeff"
    doAssert pa >= 90, "Paula join soft stays 90"
    doAssert wi >= 50

  # Leg C: AgentFourside holds max fo>=60 on Paula seat.
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FoFromPaula)), snes, cpu)
    let h = runPol(snes, cpu, AgentFoursideApproachPolicy, 4000)
    echo "C fourside hold maxFo=", h.fo, " minPy=0x", toHex(h.minPy, 4),
      " maxPy=0x", toHex(h.maxPy, 4)
    doAssert h.fo >= 60, "AgentFourside must hold/peak fo60 (got " & $h.fo & ")"
    echo "C SPINE ", checkpointSpineLine(snes)

  # Soft bands: wall approach py grades 45/50 before 60.
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Leave)), snes, cpu)
    let i = PlayerSlot * SlotIndexStride
    snes.bus.mem[0x7E0000 + WorldYBase + i] = 0x00
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = 0x17
    doAssert foursidePercent(snes) == 45, "py 0x1700 → fo45 wall approach"
    snes.bus.mem[0x7E0000 + WorldYBase + i] = 0x00
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = 0x18
    doAssert foursidePercent(snes) == 50, "py 0x1800 → fo50 past-wall approach"
    echo "D soft bands fo45/fo50 OK"

  echo "OK test_agent_paula_fo60_handoff"

when isMainModule:
  main()
