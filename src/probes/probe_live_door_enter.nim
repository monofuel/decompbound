## Continuous outdoor→home to door, then diagnose door enter.
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
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

proc main() =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/onett_start.state")), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentOutdoorPolicy, "out")
  let i = PlayerSlot * SlotIndexStride
  var home = false
  var maxK = 0
  for f in 1 .. 20000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK: maxK = k
    if pokeyPercent(snes) >= 100 and not home:
      loadChunk(L, skills, "sk2")
      loadChunk(L, AgentHomePolicy, "home")
      home = true
      echo "handoff f=", f
    if home and k >= 50:
      echo fmt"AT_DOOR f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"win1={readU8(snes,0x8654):#04x} knock={k} $9877={readU8(snes,0x9877):#04x}"
      echo "scene=", scene.sceneJson(snes)[0 ..< min(450, scene.sceneJson(snes).len)]
      # try pure Up+A like home_door_postmeteor
      for n in 1 .. 400:
        snes.joy1 = if (n mod 20) < 4: 0x0080'u16 else: 0x0800'u16
        policy.stepOneFrame(snes, c, img)
        let k2 = pokeyKnockPercent(snes)
        if k2 > maxK: maxK = k2
        if k2 >= 70:
          echo fmt"ENTER pure Up+A n={n} knock={k2} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
          break
      echo fmt"after pure Up+A maxK={maxK} room={currentRoomLabel(snes)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) win1={readU8(snes,0x8654):#04x}"
      # if still outdoor, try from home_door_postmeteor recipe: stand and more A
      if pokeyKnockPercent(snes) < 70:
        for n in 1 .. 600:
          # Up held more, A pulse
          snes.joy1 = 0x0800
          if (n mod 12) < 3: snes.joy1 = snes.joy1 or 0x0080
          policy.stepOneFrame(snes, c, img)
          let k2 = pokeyKnockPercent(snes)
          if k2 > maxK: maxK = k2
          if k2 >= 70:
            echo fmt"ENTER held-Up n={n} knock={k2}"
            break
      echo fmt"FINAL maxK={maxK} room={currentRoomLabel(snes)}"
      break
  echo "OK probe_live_door_enter"
main()
