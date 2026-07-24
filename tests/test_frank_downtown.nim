## Frank downtown: AgentFrankPolicy from post_knock_outdoor climbs frank>=60
## (south-road detour). Optionally frank>=80 deep south. Saves frank_downtown.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  DowntownOut = "bin/states/llm/frank_downtown.state"

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
  ## AgentFrankPolicy must reach frank downtown 60+ via south road (not west wall).
  doAssert fileExists(Rom)
  ensureOutdoor()
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, cpu)
  doAssert knockComplete(snes)
  let startFr = frankPercent(snes)
  echo "start frank=", startFr, " giant=", giantStepPercent(snes),
    " captain=", captainStrongPercent(snes)

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
  var maxGs = giantStepPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let ea = 0x7E0000 + KnockCompleteOff
    if snes.bus.mem[ea] != KnockCompleteVal.uint8:
      snes.bus.mem[ea] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
    if f mod 1000 == 0:
      echo "f=", f, " frank=", fr, " giant=", gs,
        " pos=(0x", toHex(readU16(snes, WorldXBase+i), 4), ",0x",
        toHex(readU16(snes, WorldYBase+i), 4), ")"
    if maxFr >= 80:
      break

  echo "FINAL max_frank=", maxFr, " max_giant=", maxGs,
    " captain=", captainStrongPercent(snes),
    " pos_x=", readU16(snes, WorldXBase+i), " pos_y=", readU16(snes, WorldYBase+i)
  doAssert maxFr >= 60, "frank downtown band is 60+ (got max=" & $maxFr & ")"
  doAssert maxGs >= 40, "giant_step must open with frank 60 (got " & $maxGs & ")"

  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  writeFile(DowntownOut, cast[string](serializeState(snes, cpu)))
  echo "WROTE ", DowntownOut, " frank=", frankPercent(snes),
    " giant=", giantStepPercent(snes)
  echo "OK test_frank_downtown: frank>=60 giant_step>=40"

when isMainModule:
  main()
