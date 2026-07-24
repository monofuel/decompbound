## $987x unlock refine + slow-dialogue live path vs pokey_free values.
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Offs = [0x9875, 0x9876, 0x9877, 0x9879, 0x987A, 0x987D]

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

proc dump987(snes: SnesBus; tag: string) =
  var s = tag
  for off in Offs:
    s.add fmt" ${off:04X}={readU8(snes,off):#04x}"
  s.add fmt" $9A0B={readU8(snes,0x9A0B):#04x}"
  echo s

proc runToPokey(drainExtra: int; aPulse: bool): tuple[snes: SnesBus, c: Cpu] =
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
  # Optional slow advanceDialogue: longer gap between A
  if aPulse:
    loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local win0 = mem.read(0x8650)
  local win1 = mem.read(0x8654)
  if win0 ~= 0xFF or win1 ~= 0xFF then
    if (frame() % 20) < 3 then pad.press("A") end
    return
  end
  if talk and talk("pokey") then return end
  if goToMeteor and goToMeteor() then return end
  if goToward and goToward("meteor_crater") then return end
  pad.press("Up")
end
""", "slowout")
  else:
    loadChunk(L, AgentOutdoorPolicy, "out")
  for f in 1 .. 6000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100:
      for e in 1 .. drainExtra:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c)

proc homeK(snes: SnesBus; c: var Cpu; frames: int): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentHomePolicy, "home")
  result = pokeyKnockPercent(snes)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > result: result = k
    if result >= 80: break

proc main() =
  # Baselines
  for path in ["bin/states/llm/pokey_done.state", "bin/states/llm/pokey_free.state"]:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    dump987(snes, path.splitPath.tail)

  var t = runToPokey(120, false)
  dump987(t.snes, "LIVE_default")
  echo "LIVE default home maxK=", homeK(t.snes, t.c, 8000)

  # Idle 600 frames after talk (no input)
  t = runToPokey(120, false)
  block:
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for _ in 1 .. 600:
      t.snes.joy1 = 0
      policy.stepOneFrame(t.snes, t.c, img)
  dump987(t.snes, "LIVE_idle600")
  echo "LIVE idle600 home maxK=", homeK(t.snes, t.c, 8000)

  # Slow dialogue outdoor
  t = runToPokey(400, true)
  dump987(t.snes, "LIVE_slow")
  echo "LIVE slow home maxK=", homeK(t.snes, t.c, 8000)

  # Copy only $987x from fixture
  let fix = newSnesBus(policy.readRomFile(Rom))
  var fc = fix.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), fix, fc)
  t = runToPokey(120, false)
  for off in Offs:
    t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
  dump987(t.snes, "LIVE_poke987x")
  echo "LIVE poke987x home maxK=", homeK(t.snes, t.c, 10000)

  # Subsets for full 80
  for (label, subset) in [
    ("9877+987A", @[0x9877, 0x987A]),
    ("9875..7A", @[0x9875, 0x9876, 0x9877, 0x9879, 0x987A]),
    ("987D only", @[0x987D]),
    ("987A only", @[0x987A]),
    ("9877 only", @[0x9877]),
  ]:
    t = runToPokey(120, false)
    for off in subset:
      t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    echo fmt"{label} maxK={homeK(t.snes, t.c, 8000)}"

  # Copy $987x from pokey_free instead
  if fileExists("bin/states/llm/pokey_free.state"):
    let pf = newSnesBus(policy.readRomFile(Rom))
    var pc = pf.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_free.state")), pf, pc)
    dump987(pf, "pokey_free_vals")
    t = runToPokey(120, false)
    for off in Offs:
      t.snes.bus.mem[0x7E0000 + off] = pf.bus.mem[0x7E0000 + off]
    echo "LIVE poke_from_free maxK=", homeK(t.snes, t.c, 8000)

  echo "OK probe_987x_home"
main()
