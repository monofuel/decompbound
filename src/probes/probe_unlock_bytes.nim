## Which of the 12 fixture bytes unlocks live AgentHome → knock80?
import std/[os, strformat, sequtils], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Offs = [0x9652, 0x9654, 0x9656, 0x9660, 0x96C5, 0x9875, 0x9876, 0x9877, 0x9879, 0x987A, 0x987D, 0x9A0B]

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

proc runLive(): tuple[snes: SnesBus, c: Cpu] =
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
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100:
      for e in 1 .. 120:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c)

proc homeMaxK(snes: SnesBus; c: var Cpu; frames: int): int =
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
    if result >= 50: break  # early stop once door-ish

proc main() =
  let fix = newSnesBus(policy.readRomFile(Rom))
  var fc = fix.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), fix, fc)
  var fixV: array[12, uint8]
  for i, off in Offs:
    fixV[i] = fix.bus.mem[0x7E0000 + off]
    echo fmt"off ${off:04X} fix={fixV[i]:#04x}"

  # Single-byte tests (short frames — door 50 is enough signal)
  for i, off in Offs:
    var t = runLive()
    let before = t.snes.bus.mem[0x7E0000 + off]
    t.snes.bus.mem[0x7E0000 + off] = fixV[i]
    let mk = homeMaxK(t.snes, t.c, 2500)
    echo fmt"single ${off:04X} {before:#04x}->{fixV[i]:#04x} maxK={mk}"

  # Leave-one-out of full set
  for drop in 0 .. 11:
    var t = runLive()
    for i, off in Offs:
      if i == drop: continue
      t.snes.bus.mem[0x7E0000 + off] = fixV[i]
    let mk = homeMaxK(t.snes, t.c, 2500)
    echo fmt"all_except ${Offs[drop]:04X} maxK={mk}"

  # Groups: timers 965x, 96C5, 987x, 9A0B
  for (label, idxs) in [
    ("965x", @[0,1,2,3]),
    ("96C5", @[4]),
    ("987x", @[5,6,7,8,9,10]),
    ("9A0B", @[11]),
    ("965x+96C5", @[0,1,2,3,4]),
    ("987x+9A0B", @[5,6,7,8,9,10,11]),
    ("96C5+987D+9A0B", @[4,10,11]),
  ]:
    var t = runLive()
    for i in idxs:
      t.snes.bus.mem[0x7E0000 + Offs[i]] = fixV[i]
    let mk = homeMaxK(t.snes, t.c, 3500)
    echo fmt"group {label} maxK={mk}"

  echo "OK probe_unlock_bytes"
main()
