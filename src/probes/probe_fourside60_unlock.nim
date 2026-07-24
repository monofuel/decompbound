## Can free midgame flags + deep prepoo position walk? Isolates map wall vs story gate.
## Also try control-unlock sequences on prepoo; write walkable fo60 if freed.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Free = "bin/states/slot4.state"
  Deep = "bin/states/llm/fourside_deep_prepoo.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc walk(snes: SnesBus; c: var Cpu; pol: string; frames: int; name: string): int =
  ## Returns max span (min+max x/y range).
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua, "sk")
  loadChunk(L, pol, name)
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
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
  result = (maxX - minX) + (maxY - minY)
  echo fmt"{name}: span={result} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} " &
    fmt"end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) fo={foursidePercent(snes)}"

const Explore = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 100
  if f < 35 then pad.press("Down")
  elseif f < 60 then pad.press("Right")
  elseif f < 80 then pad.press("Left")
  else pad.press("Up") end
end
"""

proc main() =
  doAssert fileExists(Free) and fileExists(Deep)
  # A) free flags + deep position
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Free)), snes, c)
    let deep = newSnesBus(policy.readRomFile(Rom))
    var cd = deep.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Deep)), deep, cd)
    let di = PlayerSlot * SlotIndexStride
    let dpx = readU16(deep, WorldXBase + di)
    let dpy = readU16(deep, WorldYBase + di)
    let fi = PlayerSlot * SlotIndexStride
    # Overwrite only player world X/Y on free state
    snes.bus.mem[0x7E0000 + WorldXBase + fi] = uint8(dpx and 0xFF)
    snes.bus.mem[0x7E0000 + WorldXBase + fi + 1] = uint8((dpx shr 8) and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + fi] = uint8(dpy and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + fi + 1] = uint8((dpy shr 8) and 0xFF)
    echo fmt"SYNTH free_flags+deep_pos at (0x{dpx:04X},0x{dpy:04X}) fo={foursidePercent(snes)}"
    let span = walk(snes, c, Explore, 3000, "free_flags_deep_pos")
    if span >= 64 and foursidePercent(snes) >= 60:
      writeFile("bin/states/llm/fourside60_walkable.state", cast[string](serializeState(snes, c)))
      echo "WROTE fourside60_walkable (free flags + deep pos free)"
    elif span >= 64:
      echo "NOTE: free flags at deep pos walkable but fo may regrade by py"

  # B) deep flags + free position (opposite)
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Deep)), snes, c)
    let free = newSnesBus(policy.readRomFile(Rom))
    var cf = free.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Free)), free, cf)
    let fi = PlayerSlot * SlotIndexStride
    let fpx = readU16(free, WorldXBase + fi)
    let fpy = readU16(free, WorldYBase + fi)
    let di = PlayerSlot * SlotIndexStride
    snes.bus.mem[0x7E0000 + WorldXBase + di] = uint8(fpx and 0xFF)
    snes.bus.mem[0x7E0000 + WorldXBase + di + 1] = uint8((fpx shr 8) and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + di] = uint8(fpy and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + di + 1] = uint8((fpy shr 8) and 0xFF)
    echo fmt"SYNTH deep_flags+free_pos at (0x{fpx:04X},0x{fpy:04X}) fo={foursidePercent(snes)}"
    discard walk(snes, c, Explore, 3000, "deep_flags_free_pos")

  # C) deep + poke $5E06 to free's value (map-mode hypothesis)
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Deep)), snes, c)
    let free = newSnesBus(policy.readRomFile(Rom))
    var cf = free.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Free)), free, cf)
    let freeMode = readU8(free, 0x5E06)
    let deepMode = readU8(snes, 0x5E06)
    echo fmt"POKE $5E06 0x{deepMode:02X}->0x{freeMode:02X} on deep (hypothesis control/mode)"
    snes.bus.mem[0x7E0000 + 0x5E06] = freeMode.uint8
    let span = walk(snes, c, Explore, 4000, "deep_poke_5E06")
    if span >= 64:
      writeFile("bin/states/llm/fourside60_walkable.state", cast[string](serializeState(snes, c)))
      echo "WROTE fourside60_walkable after $5E06 poke span=", span,
        " fo=", foursidePercent(snes)

  # D) deep + poke $89CA to free's
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Deep)), snes, c)
    let free = newSnesBus(policy.readRomFile(Rom))
    var cf = free.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Free)), free, cf)
    let sec = readU16(free, 0x89CA)
    echo fmt"POKE $89CA -> 0x{sec:04X} on deep"
    snes.bus.mem[0x7E0000 + 0x89CA] = uint8(sec and 0xFF)
    snes.bus.mem[0x7E0000 + 0x89CB] = uint8((sec shr 8) and 0xFF)
    discard walk(snes, c, Explore, 3000, "deep_poke_89CA")

  # E) pure deep baseline
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Deep)), snes, c)
    discard walk(snes, c, Explore, 2000, "deep_baseline")

  echo "OK probe_fourside60_unlock"

when isMainModule:
  main()
