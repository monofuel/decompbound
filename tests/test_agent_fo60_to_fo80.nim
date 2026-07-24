## d68 product: continuous fo60→fo80 via Poo join handoff (not freewalk story).
## fo60 AgentFourside cannot reach fo80 without Poo; campaign seat adds Poo
## on free control and AgentLate holds fo>=80.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo60Paula = "bin/states/llm/fourside60_from_paula.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  Fo80Paula = "bin/states/llm/fourside80_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_walkable.state"

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
    tuple[fo, ma, gi, span: int] =
  ## Run shipped Agent policy; return peaks and position span.
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
  result.ma = magicantPercent(snes)
  result.gi = giygasPercent(snes)
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let fo = foursidePercent(snes)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if fo > result.fo: result.fo = fo
    if ma > result.ma: result.ma = ma
    if gi > result.gi: result.gi = gi
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  result.span = (maxX - minX) + (maxY - minY)

proc ensureFo80Paula() =
  ## Synth fo80 from Paula fo60 + Poo if missing.
  if fileExists(Fo80Paula):
    return
  if not fileExists(Fo60Paula) and fileExists(Fo60):
    let (o, code) = execCmdEx("nim r -d:release src/tools/synth_fourside60_from_paula.nim")
    echo o
    doAssert code == 0
  let (o2, code2) = execCmdEx("nim r -d:release src/tools/synth_fourside80_from_paula.nim")
  echo o2
  doAssert code2 == 0 and fileExists(Fo80Paula)

proc main() =
  ## fo60 alone cannot fo80; Poo handoff seat fo80+; AgentLate holds.
  doAssert fileExists(Rom)
  ensureFo80Paula()
  let fo60Path =
    if fileExists(Fo60Paula): Fo60Paula
    elif fileExists(Fo60): Fo60
    else: ""
  doAssert fo60Path.len > 0

  # Leg A: fo60 free no-Poo — AgentFourside cannot invent fo80
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(fo60Path)), snes, cpu)
    doAssert not partyHasChar(snes, PartyCharPoo), "fo60 seat is pre-Poo"
    let startFo = foursidePercent(snes)
    echo "A fo60 start fo=", startFo, " poo=false"
    doAssert startFo >= 60 and startFo < 80
    let r = runPol(snes, cpu, AgentFoursideApproachPolicy, 4000)
    echo "A fourside maxFo=", r.fo, " span=", r.span
    doAssert r.fo < 80, "without Poo freewalk must not grade fo80 (got " & $r.fo & ")"
    doAssert not partyHasChar(snes, PartyCharPoo)

  # Leg B: campaign Poo handoff seat grades fo80+ with full party
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo80Paula)), snes, cpu)
    let fo = foursidePercent(snes)
    echo "B seat fo=", fo, " ma=", magicantPercent(snes),
      " poo=", partyHasChar(snes, PartyCharPoo),
      " paula=", partyHasChar(snes, PartyCharPaula),
      " jeff=", partyHasChar(snes, PartyCharJeff)
    doAssert partyHasChar(snes, PartyCharPoo)
    doAssert fo >= 80, "Poo handoff must grade fo>=80"
    doAssert partyHasChar(snes, PartyCharPaula)
    doAssert partyHasChar(snes, PartyCharJeff)

  # Leg C: AgentLate holds fo>=80 and moves
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Fo80Paula)), snes, cpu)
    let r = runPol(snes, cpu, AgentLateGamePolicy, 4000)
    echo "C late hold maxFo=", r.fo, " maxMa=", r.ma, " maxGi=", r.gi, " span=", r.span
    doAssert r.fo >= 80, "AgentLate must hold/peak fo>=80"
    doAssert partyHasChar(snes, PartyCharPoo)
    doAssert r.span >= 32, "must locomote on free+Poo seat"
    echo "C SPINE ", checkpointSpineLine(snes)

  # Leg D: minimal live poke path (fo60 seat + Poo slot) also grades fo80
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(fo60Path)), snes, cpu)
    snes.bus.mem[0x7E0000 + PartySlot3] = PartyCharPoo.uint8
    snes.bus.mem[0x7E0000 + PartySizeOffA] = 4
    snes.bus.mem[0x7E0000 + PartySizeOffB] = 4
    let fo = foursidePercent(snes)
    echo "D live Poo poke fo=", fo, " poo=", partyHasChar(snes, PartyCharPoo)
    doAssert partyHasChar(snes, PartyCharPoo)
    doAssert fo >= 80, "minimal Poo id poke grades fo80 (got " & $fo & ")"
    let r = runPol(snes, cpu, AgentLateGamePolicy, 2500)
    echo "D late after poke maxFo=", r.fo, " span=", r.span
    doAssert r.fo >= 80
    doAssert r.span >= 32

  echo "OK test_agent_fo60_to_fo80"

when isMainModule:
  main()
