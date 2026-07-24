## From battle_menu_healthy: winBattle then walk; capture post-battle midgame if free.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  let path = "bin/states/battle_menu_healthy.state"
  if not fileExists(path):
    echo "SKIP no battle fixture"
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  echo "START ", checkpointSpineLine(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 100
  if f < 40 then pad.press("Down")
  elseif f < 70 then pad.press("Right")
  else pad.press("Left") end
end
""", "pol")
  let i = PlayerSlot * SlotIndexStride
  var minX = 0xFFFF
  var maxX = 0
  var minY = 0xFFFF
  var maxY = 0
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    if f mod 1500 == 0:
      echo fmt"f={f} pos=(0x{px:04X},0x{py:04X}) belch={belchPercent(snes)} fourside={foursidePercent(snes)}"
  let span = (maxX - minX) + (maxY - minY)
  echo "FINAL ", checkpointSpineLine(snes)
  echo fmt"span={span} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X}"
  if span >= 64:
    writeFile("bin/states/llm/post_battle_midgame.state",
      cast[string](serializeState(snes, cpu)))
    echo "WROTE post_battle_midgame"

when isMainModule:
  main()
