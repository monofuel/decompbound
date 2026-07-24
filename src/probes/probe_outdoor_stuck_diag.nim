## Diagnose zero-joy stall near meteor site from onett_start climb.
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

# Diagnostic policy: print which branch fires
const DiagPol = """
function update()
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if escapeMenu() then print("BR escape"); return end
  if inBattle() then print("BR battle"); winBattle(); return end
  if advanceDialogue and advanceDialogue() then print("BR dialogue"); return end
  local nearDoor = (math.abs(px - 0x0A60) + math.abs(py - 0x0158)) < 0x50
  if nearDoor then print("BR door"); if goToward then goToward("meteor_crater") end; pad.press("Left"); return end
  if talk and talk("pokey") then print("BR talk_pokey"); return end
  local e = nearestEntity and nearestEntity() or nil
  if e ~= nil and e.dist_tiles and e.dist_tiles <= 6 then
    local n = e.name or ""
    if n == "pokey" or n == "mom" then
      if talk(e.slot) then print("BR talk_slot "..n); return end
    end
  end
  if goToward then
    if goToward("meteor_crater") then print("BR go_meteor"); return end
    if goToward("crater_ridge") then print("BR go_ridge"); return end
    if goToward("hill_climb") then print("BR go_hill"); return end
  end
  print("BR pad_explore")
  pad.press("Up")
end
"""

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
  loadChunk(L, DiagPol, "diag")
  let i = PlayerSlot * SlotIndexStride
  var maxP = pokeyPercent(snes)
  for f in 1 .. 3000:
    ctx.frameCount = f
    ctx.joy1 = 0
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let p = pokeyPercent(snes)
    if p > maxP: maxP = p
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if f mod 200 == 0 or (ctx.joy1 == 0 and f > 500 and f mod 50 == 0):
      echo fmt"f={f} pokey={p} max={maxP} pos=(0x{px:04X},0x{py:04X}) joy={ctx.joy1:#06x}"
    if maxP >= 80: break
  echo "FINAL max_pokey=", maxP

main()
