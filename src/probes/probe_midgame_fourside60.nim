## From freest midgame outdoor, push south for fourside 60 (py>=0x1A00).
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  let path =
    if fileExists("bin/states/slot4.state"): "bin/states/slot4.state"
    else: "bin/states/llm/midgame_approach.state"
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  echo "START path=", path, " ", checkpointSpineLine(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  # Prefer pure south for fourside 60 band
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py < 0x1A00 then
    pad.press("Down")
    if (frame() % 40) < 12 then pad.press("Right") end
    if (frame() % 40) >= 28 then pad.press("Left") end
    return
  end
  pad.press("Down")
  if (frame() % 30) < 10 then pad.press("Left") end
end
""", "south60")
  var maxFo = foursidePercent(snes)
  var maxPy = 0
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let py = readU16(snes, WorldYBase+i)
    if py > maxPy: maxPy = py
    let fo = foursidePercent(snes)
    if fo > maxFo:
      maxFo = fo
      echo fmt"NEW fourside={fo} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{py:04X})"
    if maxFo >= 60: break
    if f mod 3000 == 0:
      echo fmt"f={f} fo={fo} maxPy=0x{maxPy:04X} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{py:04X})"
  echo fmt"FINAL max_fo={maxFo} maxPy=0x{maxPy:04X} ", checkpointSpineLine(snes)
  if maxFo >= 60:
    writeFile("bin/states/llm/fourside60_agent.state", cast[string](serializeState(snes, c)))
    echo "WROTE fourside60_agent"
  echo "OK probe_midgame_fourside60"

when isMainModule: main()
