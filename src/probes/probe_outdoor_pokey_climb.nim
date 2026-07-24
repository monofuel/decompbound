## Free outdoor pokey climb from onett_start — log position/band for ridge→site wall.
import std/[os, strformat, strutils], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Path = "bin/states/llm/onett_start.state"

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
  doAssert fileExists(Path)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Path)), snes, c)
  echo "START pokey=", pokeyPercent(snes), " spine=", checkpointSpineLine(snes)
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
  var maxP = pokeyPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  var stuck = 0
  var prevX = readU16(snes, WorldXBase+i)
  var prevY = readU16(snes, WorldYBase+i)
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let p = pokeyPercent(snes)
    if p > maxP: maxP = p
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    let d = abs(px - prevX) + abs(py - prevY)
    if d <= 1: stuck.inc else: stuck = 0
    prevX = px; prevY = py
    if f mod 1000 == 0 or (p > maxP - 1 and f mod 200 == 0):
      echo fmt"f={f} pokey={p} max={maxP} pos=(0x{px:04X},0x{py:04X}) stuck={stuck} joy={ctx.joy1:#06x}"
    if maxP >= 100: break
  echo "FINAL max_pokey=", maxP
  doAssert maxP >= 80, "outdoor free climb must hit site (pokey 80+); got " & $maxP
  echo "OK probe_outdoor_pokey_climb: onett_start pokey max=", maxP

main()
