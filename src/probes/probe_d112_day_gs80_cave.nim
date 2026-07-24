## d112: after day outdoor freeplay hits gs80, hunt cave indoor (pure Up / N/NE/NW).
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  BtnUp = 0x0800'u16
  BtnRight = 0x0100'u16
  BtnLeft = 0x0200'u16

proc loadChunk(L: lua53.PState; src, label: string) =
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

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

proc freeplayToGs80(snes: SnesBus; c: var Cpu) =
  ## Day outdoor freeplay frank then giant until gs80.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skills(), "skills")
  for pol in [AgentFrankPolicy, AgentGiantStepPolicy]:
    loadChunk(L, pol, "pol")
    let stopGs = if pol == AgentGiantStepPolicy: 80 else: 0
    let stopFr = if pol == AgentFrankPolicy: 80 else: 0
    for f in 1 .. 8000:
      clearSouthFreezeLocks(snes)
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      applyDayStoryOpen(snes)
      clearSouthFreezeLocks(snes)
      if stopFr > 0 and frankPercent(snes) >= stopFr and f >= 1500: break
      if stopGs > 0 and giantStepPercent(snes) >= stopGs and f >= 1500: break

proc main() =
  echo "PROBE=d112 cave hunt from continuous day gs80 freeplay seat"
  var snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  applyDayStoryOpen(snes)
  clearSouthFreezeLocks(snes)
  freeplayToGs80(snes, c)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GS80_SEAT gs={giantStepPercent(snes)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) day={dayStoryOpen(snes)}"
  doAssert giantStepPercent(snes) >= 80

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var indoorHits = 0
  var maxGs = giantStepPercent(snes)
  var minY = readU16(snes, WorldYBase + i).int
  var maxY = minY
  for mix in 0 .. 2:
    # re-seat freeplay if needed
    if giantStepPercent(snes) < 80:
      freeplayToGs80(snes, c)
    let joy =
      case mix
      of 0: BtnUp
      of 1: BtnUp or BtnRight
      else: BtnUp or BtnLeft
    for f in 1 .. 2500:
      clearSouthFreezeLocks(snes)
      snes.joy1 = joy
      policy.stepOneFrame(snes, c, img)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      applyDayStoryOpen(snes)
      clearSouthFreezeLocks(snes)
      let px = readU16(snes, WorldXBase + i).int
      let py = readU16(snes, WorldYBase + i).int
      if px >= 0x1C00: inc indoorHits
      if py < minY: minY = py
      if py > maxY: maxY = py
      let gs = giantStepPercent(snes)
      if gs > maxGs: maxGs = gs
      if gs >= 100:
        echo fmt"CAVE_100 mix={mix} f={f} pos=(0x{px:04X},0x{py:04X})"
        break
    echo fmt"MIX{mix} indoor={indoorHits} maxGs={maxGs} y=0x{minY:04X}..0x{maxY:04X}"

  echo fmt"SUMMARY indoor={indoorHits} maxGs={maxGs} minY=0x{minY:04X}"
  if indoorHits == 0 and maxGs < 100:
    echo "NOTE cave freewalk still blocked from continuous day gs80 seat"
  echo "OK probe_d112_day_gs80_cave"

when isMainModule: main()
