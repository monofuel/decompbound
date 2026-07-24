## Can free midgame flags walk any py band between fo40 (0x1600) and fo60 (0x1A00)?
## Isolates map wall height vs full deep teleport.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Free = "bin/states/slot4.state"
  Mid = "bin/states/llm/midgame_approach.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc setPos(snes: SnesBus; x, y: int) =
  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc walkSpan(snes: SnesBus; c: var Cpu; frames: int): tuple[span, maxFo, maxPy: int] =
  ## Hold south-biased walk; return span, peak fo, peak py.
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
  pad.press("Down")
  local f = frame() % 40
  if f < 12 then pad.press("Right")
  elseif f < 24 then pad.press("Left") end
end
""", "south")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var maxFo = foursidePercent(snes)
  var maxPy = minY
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
    if py > maxPy: maxPy = py
    let fo = foursidePercent(snes)
    if fo > maxFo: maxFo = fo
  result = ((maxX - minX) + (maxY - minY), maxFo, maxPy)

proc main() =
  ## Try free flags at increasing py from midgame pocket toward fo60.
  doAssert fileExists(Rom) and fileExists(Free)
  let base = newSnesBus(policy.readRomFile(Rom))
  var cb = base.resetCpu()
  let startPath = if fileExists(Mid): Mid else: Free
  deserializeState(cast[seq[byte]](readFile(startPath)), base, cb)
  let bi = PlayerSlot * SlotIndexStride
  let baseX = readU16(base, WorldXBase + bi)
  let baseY = readU16(base, WorldYBase + bi)
  echo fmt"BASE {extractFilename(startPath)} pos=(0x{baseX:04X},0x{baseY:04X}) fo={foursidePercent(base)}"

  # py targets from mid ~0x17F8 toward 0x1A00 and beyond
  for py in [0x17F8, 0x1850, 0x1900, 0x1980, 0x1A00, 0x1B00, 0x1C00, 0x2000, 0x23EB]:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Free)), snes, c)
    setPos(snes, baseX, py)
    let fo0 = foursidePercent(snes)
    let w = walkSpan(snes, c, 2000)
    echo fmt"py=0x{py:04X} start_fo={fo0} span={w.span} maxFo={w.maxFo} maxPy=0x{w.maxPy:04X}"
    if w.span >= 64 and w.maxFo >= 60:
      let outp = "bin/states/llm/fourside60_from_band.state"
      writeFile(outp, cast[string](serializeState(snes, c)))
      echo "WROTE ", outp, " after walk fo=", foursidePercent(snes)
  echo "OK probe_midgame_py_bands"

when isMainModule:
  main()
