## Frank corridor past 40: AgentFrankPolicy from post_knock_outdoor climbs frank>=50
## and buzz>=55 (mid-town). Saves frank_corridor fixture when green.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  FrankOut = "bin/states/llm/frank_corridor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc ensureOutdoor() =
  if fileExists(OutdoorPk): return
  let (o, c) = execCmdEx("nim r -d:release src/tools/synth_post_knock_outdoor.nim")
  echo o
  doAssert c == 0 and fileExists(OutdoorPk)

proc main() =
  ## AgentFrankPolicy must climb frank past 40 from free outdoor post-knock.
  doAssert fileExists(Rom)
  ensureOutdoor()
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, cpu)
  doAssert knockComplete(snes)
  doAssert touchGrassPercent(snes) >= 100
  let startFr = frankPercent(snes)
  let startBb = buzzBuzzPercent(snes)
  echo "start frank=", startFr, " buzz=", startBb, " knock=", pokeyKnockPercent(snes)

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentFrankPolicy, "frank")

  var maxFr = startFr
  var maxBb = startBb
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # Keep knock signature if the game clears it mid-walk (synth bootstrap).
    let ea = 0x7E0000 + KnockCompleteOff
    if snes.bus.mem[ea] != KnockCompleteVal.uint8:
      snes.bus.mem[ea] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let bb = buzzBuzzPercent(snes)
    if fr > maxFr: maxFr = fr
    if bb > maxBb: maxBb = bb
    if f mod 1000 == 0:
      echo "f=", f, " frank=", fr, " buzz=", bb, " pos_x=", readU16(snes, WorldXBase+i),
        " pos_y=", readU16(snes, WorldYBase+i)
    if maxFr >= 50 and maxBb >= 55:
      break

  echo "FINAL max_frank=", maxFr, " max_buzz=", maxBb,
    " pos_x=", readU16(snes, WorldXBase+i), " pos_y=", readU16(snes, WorldYBase+i)
  doAssert maxFr > 40, "frank must climb past 40 (got max=" & $maxFr & ")"
  doAssert maxFr >= 50, "frank mid-town band is 50+ (got " & $maxFr & ")"
  doAssert maxBb > 40, "buzz must climb past 40 mid-town (got " & $maxBb & ")"
  doAssert maxBb >= 55, "buzz mid-town is 55+ (got " & $maxBb & ")"

  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let bytes = serializeState(snes, cpu)
  writeFile(FrankOut, cast[string](bytes))
  echo "WROTE ", FrankOut, " frank=", frankPercent(snes), " buzz=", buzzBuzzPercent(snes)
  echo "OK test_frank_corridor: frank/buzz climbed past 40"

when isMainModule:
  main()
