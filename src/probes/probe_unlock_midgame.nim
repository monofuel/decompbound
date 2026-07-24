## Try unlock patterns on locked midgame slots (span was 0).
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK: raise newException(ValueError, $L.toString(-1))

proc tryPath(path, pol: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, pol, "p")
  let i = PlayerSlot * SlotIndexStride
  let sx = readU16(snes, WorldXBase+i)
  let sy = readU16(snes, WorldYBase+i)
  var minX=sx; var maxX=sx; var minY=sy; var maxY=sy
  for f in 1..4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX-minX)+(maxY-minY)
  echo fmt"{extractFilename(path)} span={span} start=(0x{sx:04X},0x{sy:04X}) end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) fourside={foursidePercent(snes)}"
  if span >= 200 and foursidePercent(snes) >= 40:
    writeFile("bin/states/llm/midgame_deep.state", cast[string](serializeState(snes, c)))
    echo "WROTE midgame_deep"

const UnlockPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  -- mash dialogue / menu
  local t = frame() % 80
  if t < 15 then pad.press("A")
  elseif t < 25 then pad.press("B")
  elseif t < 40 then pad.press("Down")
  elseif t < 55 then pad.press("Right")
  elseif t < 70 then pad.press("Left")
  else pad.press("Up") end
end
"""

proc main() =
  for p in ["bin/states/slot73.state", "bin/states/slot75.state",
            "bin/states/slot77.state", "bin/states/slot130.state",
            "bin/states/slot72.state"]:
    tryPath(p, UnlockPol)

when isMainModule: main()
