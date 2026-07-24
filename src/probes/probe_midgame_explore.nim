## Headless explore from midgame slot1; log pos + spine (next after winters soft).
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
  let path =
    if fileExists("bin/states/slot1.state"): "bin/states/slot1.state"
    else: ""
  doAssert path.len > 0
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
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
  local f = frame() % 120
  if f < 40 then pad.press("Right")
  elseif f < 70 then pad.press("Down")
  elseif f < 100 then pad.press("Left")
  else pad.press("Up") end
end
""", "explore")
  let i = PlayerSlot * SlotIndexStride
  var minX, minY = 0xFFFF
  var maxX, maxY = 0
  echo fmt"START pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo "  ", checkpointSpineLine(snes)
  for f in 1 .. 4000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if py < minY: minY = py
    if px > maxX: maxX = px
    if py > maxY: maxY = py
    if f mod 1000 == 0:
      echo fmt"f={f} pos=(0x{px:04X},0x{py:04X}) winters={wintersPercent(snes)} paula={paulaRescuePercent(snes)}"
  echo fmt"FINAL pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo fmt"  bbox x=0x{minX:04X}..0x{maxX:04X} y=0x{minY:04X}..0x{maxY:04X}"
  echo "  ", checkpointSpineLine(snes)
  echo "OK probe_midgame_explore"

when isMainModule: main()
