## Free-walk fo40→60 without campaign state load.
## Tries: (A) pure midgame free flags walk south lanes
##        (B) free flags + minimal py poke to wall face then free walk
##        (C) free flags at 0x1850 free walk to 0x1A00 (not full fo60 fixture)

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Mid = "bin/states/llm/midgame_approach.state"
  FreeSlot = "bin/states/slot4.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"

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

proc copyFlags(dst, src: SnesBus; a, b: int) =
  for off in a .. b:
    dst.bus.mem[0x7E0000 + off] = src.bus.mem[0x7E0000 + off]

const LaneSouth = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 120
  if f < 70 then pad.press("Down")
  elseif f < 95 then pad.press("Right")
  else pad.press("Left") end
end
"""

const LaneWestSouth = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 140
  if f < 50 then pad.press("Left")
  elseif f < 100 then pad.press("Down")
  else pad.press("Right") end
end
"""

const LaneEastSouth = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 140
  if f < 50 then pad.press("Right")
  elseif f < 100 then pad.press("Down")
  else pad.press("Left") end
end
"""

proc runWalk(path, pol, label: string; frames: int; pokeX, pokeY: int): tuple[maxFo, maxPy, span: int] =
  if not fileExists(path):
    echo "SKIP ", label, " missing ", path
    return (0, 0, 0)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  # Prefer free control flags from slot4 when available (mid flags may lock).
  if fileExists(FreeSlot) and path != FreeSlot:
    let free = newSnesBus(policy.readRomFile(Rom))
    var fc = free.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FreeSlot)), free, fc)
    # Event flag region + late story bytes used for free locomotion
    copyFlags(snes, free, 0x9A00, 0x9BFF)
    copyFlags(snes, free, 0x9880, 0x98FF)
  if pokeX > 0:
    setPos(snes, pokeX, pokeY)
  let startFo = foursidePercent(snes)
  let i = PlayerSlot * SlotIndexStride
  var sx = readU16(snes, WorldXBase + i)
  var sy = readU16(snes, WorldYBase + i)
  echo fmt"=== {label} start fo={startFo} pos=(0x{sx:04X},0x{sy:04X}) frames={frames} ==="
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, pol, "walk")
  var maxFo = startFo
  var maxPy = sy
  var minX = sx; var maxX = sx; var minY = sy; var maxY = sy
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let fo = foursidePercent(snes)
    if fo > maxFo: maxFo = fo
    if py > maxPy: maxPy = py
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX - minX) + (maxY - minY)
  echo fmt"FINAL {label} max_fo={maxFo} max_py=0x{maxPy:04X} span={span} " &
    fmt"bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X}"
  result = (maxFo, maxPy, span)

proc main() =
  doAssert fileExists(Rom)
  # A: pure free-flag midgame from current pos
  discard runWalk(if fileExists(Mid): Mid else: FreeSlot, LaneSouth, "A_south", 6000, 0, 0)
  discard runWalk(if fileExists(Mid): Mid else: FreeSlot, LaneWestSouth, "A_west_south", 6000, 0, 0)
  discard runWalk(if fileExists(Mid): Mid else: FreeSlot, LaneEastSouth, "A_east_south", 6000, 0, 0)
  # B: free flags at wall face py=0x17F8 — free walk only
  let base = if fileExists(Mid): Mid else: FreeSlot
  # read start x from mid for poke
  var startX = 0x1AA5
  if fileExists(base):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(base)), snes, c)
    startX = readU16(snes, WorldXBase + PlayerSlot * SlotIndexStride)
  discard runWalk(base, LaneSouth, "B_wall_face_17F8", 8000, startX, 0x17F8)
  # C: free flags at py=0x1850 free walk toward 0x1A00
  discard runWalk(base, LaneSouth, "C_from_1850", 8000, startX, 0x1850)
  discard runWalk(base, LaneSouth, "C_from_1980", 8000, startX, 0x1980)
  # D: free walk hold on existing fo60 walkable (no campaign mid-run load)
  if fileExists(Fo60):
    discard runWalk(Fo60, LaneSouth, "D_fo60_free_hold", 4000, 0, 0)
  echo "OK probe_free_fo60_breakout"

main()
