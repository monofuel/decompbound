## From midgame_approach push south/east; log max py and fourside.
import
  std/strformat,
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/midgame_approach.state")), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle and inBattle() then
    if winBattle then winBattle() end
    return
  end
  pad.press("Down")
  if (frame() % 40) < 12 then pad.press("Right") end
  if (frame() % 40) >= 28 then pad.press("Left") end
end
""", "south")
  # load winBattle
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk2")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Down")
  if (frame() % 40) < 12 then pad.press("Right") end
  if (frame() % 40) >= 28 then pad.press("Left") end
end
""", "south2")
  let i = PlayerSlot * SlotIndexStride
  var maxPy = readU16(snes, WorldYBase+i)
  var maxF = foursidePercent(snes)
  echo fmt"START pos=(0x{readU16(snes,WorldXBase+i):04X},0x{maxPy:04X}) fourside={maxF}"
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let py = readU16(snes, WorldYBase+i)
    if py > maxPy: maxPy = py
    let fo = foursidePercent(snes)
    if fo > maxF:
      maxF = fo
      echo fmt"NEW fourside={maxF} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{py:04X})"
    if f mod 2000 == 0:
      echo fmt"f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{py:04X}) maxPy=0x{maxPy:04X} fourside={fo}"
  echo fmt"FINAL maxPy=0x{maxPy:04X} max_fourside={maxF}"
  echo checkpointSpineLine(snes)
  if maxPy > 0x17F8:
    writeFile("bin/states/llm/fourside_approach.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE fourside_approach"

when isMainModule: main()
