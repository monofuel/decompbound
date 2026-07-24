import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Path = "bin/states/llm/onett_start.state"
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
  deserializeState(cast[seq[byte]](readFile(Path)), snes, c)
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
  for f in 1 .. 1500:
    ctx.frameCount = f
    ctx.joy1 = 0
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
  let px = readU16(snes, WorldXBase+i)
  let py = readU16(snes, WorldYBase+i)
  echo fmt"AT f=1500 pos=(0x{px:04X},0x{py:04X}) pokey={pokeyPercent(snes)} joy={ctx.joy1:#06x}"
  echo "win0=", readU8(snes, 0x8650), " win1=", readU8(snes, 0x8654)
  echo "scene=", scene.sceneJson(snes)
  echo "armed=", readU8(snes, MeteorArmFlag)
  # one more frame with diag
  let dump = """
function update()
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  print(string.format("pos %x %x", px, py))
  print("win", mem.read(0x8650), mem.read(0x8654))
  print("escape", escapeMenu())
  print("battle", inBattle())
  if advanceDialogue then print("adv", advanceDialogue()) end
  print("talk_pokey", talk and talk("pokey"))
  local e = nearestEntity and nearestEntity()
  if e then print("nearest", e.name, e.slot, e.dist_tiles) else print("nearest nil") end
  print("go_meteor", goToward and goToward("meteor_crater"))
end
"""
  loadChunk(L, dump, "dump")
  ctx.joy1 = 0
  discard policy.runPolicyFrame(L, ctx)
  echo "after dump joy=", ctx.joy1
main()
