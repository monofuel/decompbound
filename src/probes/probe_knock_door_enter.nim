## Free knock 50→80: AgentHome / PokeyKnock / doorEnter from door fixtures.
import std/[os, strformat, strutils], pixie
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

proc runPol(path, pol, label: string; frames: int; product: bool) =
  if not fileExists(path):
    echo "SKIP ", label, " missing ", path
    return
  if product and "followRoute(" in pol:
    echo "SKIP ", label, " product body has followRoute"
    return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let startK = pokeyKnockPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"=== {label} from {path} start_knock={startK} frames={frames} ==="
  echo "POLICY body_len=", pol.len
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" &
    IntentNavSkillLua & "\n" & DoorEnterSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, pol, label)
  var maxK = startK
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK: maxK = k
    if f mod 1500 == 0:
      let px = readU16(snes, WorldXBase+i)
      let py = readU16(snes, WorldYBase+i)
      echo fmt"f={f} knock={k} max={maxK} room={currentRoomLabel(snes)} pos=(0x{px:04X},0x{py:04X}) joy={ctx.joy1:#06x}"
    if maxK >= 80: break
  let px = readU16(snes, WorldXBase+i)
  let py = readU16(snes, WorldYBase+i)
  echo fmt"FINAL {label} max_knock={maxK} live={pokeyKnockPercent(snes)} " &
    fmt"room={currentRoomLabel(snes)} pos=(0x{px:04X},0x{py:04X})"
  echo fmt"DELTA knock {startK}->{maxK}"

proc main() =
  # Door fixtures (knock 50)
  for path in ["bin/states/llm/home_door_postmeteor.state", "bin/states/llm/home_door.state", "bin/states/llm/onett_start.state"]:
    runPol(path, AgentHomePolicy, "AgentHome_" & extractFilename(path), 8000, true)
  # Scripted referee for comparison
  runPol("bin/states/llm/home_door_postmeteor.state", PokeyKnockPolicy, "PokeyKnock_home_door_postmeteor", 8000, false)
  # Indoor 70→80
  for path in ["bin/states/llm/home_indoor.state", "bin/states/llm/home_downstairs_night.state"]:
    runPol(path, AgentHomePolicy, "AgentHome_indoor_" & extractFilename(path), 6000, true)
  # Full product from pokey_done
  runPol("bin/states/llm/pokey_done.state", AgentHomePolicy, "AgentHome_pokey_done", 12000, true)
  echo "OK probe_knock_door_enter"

main()
