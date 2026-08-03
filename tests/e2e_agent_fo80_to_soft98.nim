## d69 product: fo80 free+Poo cannot freewalk bitpop to soft98 — campaign
## soft-flag handoff seats ma98/gi80; AgentLate holds.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fo80Paula = "bin/states/llm/fourside80_from_paula.state"
  Fo80 = "bin/states/llm/fourside80_walkable.state"
  Soft98From = "bin/states/llm/soft98_from_fo80paula.state"
  Soft98 = "bin/states/llm/poo_soft98_walkable.state"

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

proc runLate(snes: SnesBus; cpu: var Cpu; maxFrames: int):
    tuple[ma, gi, bp, span: int] =
  ## AgentLateGame; return peaks and span.
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
  loadChunk(L, AgentLateGamePolicy, "late")
  let i = PlayerSlot * SlotIndexStride
  result.ma = magicantPercent(snes)
  result.gi = giygasPercent(snes)
  result.bp = eventFlagBitPop(snes)
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    let bp = eventFlagBitPop(snes)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if ma > result.ma: result.ma = ma
    if gi > result.gi: result.gi = gi
    if bp > result.bp: result.bp = bp
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  result.span = (maxX - minX) + (maxY - minY)

proc ensureSoft98From() =
  ## Synth soft98 from fo80 if missing.
  if fileExists(Soft98From):
    return
  let (o, code) = execCmdEx("nim r -d:release src/tools/synth_soft98_from_fo80.nim")
  echo o
  doAssert code == 0 and fileExists(Soft98From)

proc main() =
  ## fo80 freewalk cannot climb soft98; flag handoff seats ma98; late holds.
  doAssert fileExists(Rom)
  ensureSoft98From()
  let fo80Path =
    if fileExists(Fo80Paula): Fo80Paula
    elif fileExists(Fo80): Fo80
    else: ""
  doAssert fo80Path.len > 0

  # Leg A: fo80 freewalk does not raise bitpop to soft98 (need flag handoff)
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(fo80Path)), snes, cpu)
    doAssert partyHasChar(snes, PartyCharPoo)
    let startMa = magicantPercent(snes)
    let startBp = eventFlagBitPop(snes)
    let startSoft = hasAllSanctuarySoft(snes)
    echo "A fo80 start ma=", startMa, " bp=", startBp, " soft=", startSoft
    if not startSoft and startBp < EventFlagBitPopLateDeep:
      let r = runLate(snes, cpu, 6000)
      echo "A late climb maxMa=", r.ma, " maxBp=", r.bp, " span=", r.span
      doAssert not hasAllSanctuarySoft(snes),
        "freewalk must not invent soft98 (start bp=" & $startBp & ")"
      doAssert r.ma < 98, "freewalk maxMa must stay <98 without flag handoff"
      doAssert r.bp < EventFlagBitPopLateDeep or r.bp <= startBp + 20
      doAssert not hasMagicantDreamFlag(snes), "dream 100 still blocked"
    else:
      echo "A skip freewalk ceiling (base already soft or high bitpop)"

  # Leg B: soft98 handoff seat grades ma98/gi80
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Soft98From)), snes, cpu)
    let ma = magicantPercent(snes)
    let gi = giygasPercent(snes)
    echo "B seat ma=", ma, " gi=", gi, " soft=", hasAllSanctuarySoft(snes),
      " bp=", eventFlagBitPop(snes), " dream=", hasMagicantDreamFlag(snes)
    doAssert hasAllSanctuarySoft(snes)
    doAssert ma >= 98
    doAssert gi >= 80
    doAssert not hasMagicantDreamFlag(snes), "ma100 dream still open RE"
    doAssert not hasGiygasPhaseFlag(snes), "gi100 phase still open RE"
    doAssert partyHasChar(snes, PartyCharPoo)

  # Leg C: AgentLate holds soft98
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var cpu = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Soft98From)), snes, cpu)
    let r = runLate(snes, cpu, 4000)
    echo "C late hold maxMa=", r.ma, " maxGi=", r.gi, " span=", r.span
    doAssert r.ma >= 98
    doAssert r.gi >= 80
    doAssert r.span >= 32
    doAssert not hasMagicantDreamFlag(snes)
    echo "C SPINE ", checkpointSpineLine(snes)

  # Leg D: baseline soft98 fixture still holds (regression)
  if fileExists(Soft98):
    block:
      let snes = newSnesBus(policy.readRomFile(Rom))
      var cpu = snes.resetCpu()
      deserializeState(cast[seq[byte]](readFile(Soft98)), snes, cpu)
      doAssert magicantPercent(snes) >= 98
      let r = runLate(snes, cpu, 2500)
      echo "D soft98 fixture maxMa=", r.ma, " maxGi=", r.gi
      doAssert r.ma >= 98 and r.gi >= 80

  echo "OK test_agent_fo80_to_soft98"

when isMainModule:
  main()
