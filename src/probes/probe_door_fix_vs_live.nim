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

proc dump(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"knock={pokeyKnockPercent(snes)} win1={readU8(snes,0x8654):#04x} " &
    fmt"$9877={readU8(snes,0x9877):#04x} $987A={readU8(snes,0x987A):#04x} $99F2={readU8(snes,0x99F2):#04x}"

proc main() =
  for path in ["bin/states/llm/home_door_postmeteor.state", "bin/states/llm/home_door.state",
               "bin/states/llm/pokey_done.state"]:
    if not fileExists(path): continue
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    dump(snes, path.splitPath.tail)

  # Live to door then clear 9877 bit0 + seat + UpA
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
  var home = false
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100 and not home:
      loadChunk(L, skills, "sk2")
      loadChunk(L, AgentHomePolicy, "home")
      home = true
    if home and pokeyKnockPercent(snes) >= 50:
      dump(snes, "LIVE_door")
      # clear bit0
      let v = readU8(snes, 0x9877)
      snes.bus.mem[0x7E0000 + 0x9877] = uint8(v and 0xFE)
      echo fmt"cleared $9877 -> {readU8(snes,0x9877):#04x}"
      # seat to 0x0A60,0x0158
      for _ in 1 .. 80:
        let px = readU16(snes, WorldXBase+i)
        let py = readU16(snes, WorldYBase+i)
        if abs(px.int - 0x0A60) <= 2 and abs(py.int - 0x0158) <= 2: break
        if px < 0x0A60: snes.joy1 = 0x0100
        elif px > 0x0A60: snes.joy1 = 0x0200
        elif py > 0x0158: snes.joy1 = 0x0800
        else: snes.joy1 = 0x0400
        policy.stepOneFrame(snes, c, img)
      dump(snes, "seated")
      var maxK = pokeyKnockPercent(snes)
      for n in 1 .. 800:
        snes.joy1 = 0x0800
        if (n mod 12) < 3: snes.joy1 = snes.joy1 or 0x0080
        policy.stepOneFrame(snes, c, img)
        let k = pokeyKnockPercent(snes)
        if k > maxK: maxK = k
        if maxK >= 80: break
      echo fmt"after seat+UpA maxK={maxK} room={currentRoomLabel(snes)}"
      # also try AgentHome after clear without seat
      break

  # Fresh live door + AgentHome after always-clear $9877 bit0 (anywhere)
  block:
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
    # wrap goHome already clears meteor; patch AgentHome to clear bit0 always outdoors
    loadChunk(L, AgentOutdoorPolicy, "out")
    var home = false
    var maxK = 0
    for f in 1 .. 16000:
      ctx.frameCount = f
      if home:
        # force clear every frame outdoors
        let v = readU8(snes, 0x9877)
        if (v and 1) != 0:
          snes.bus.mem[0x7E0000 + 0x9877] = uint8(v and 0xFE)
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let k = pokeyKnockPercent(snes)
      if k > maxK: maxK = k
      if pokeyPercent(snes) >= 100 and not home:
        loadChunk(L, skills, "sk2")
        loadChunk(L, AgentHomePolicy, "home")
        home = true
      if maxK >= 80: break
    echo "continuous always-clear-bit0 maxK=", maxK, " room=", currentRoomLabel(snes)

  echo "OK"
main()
