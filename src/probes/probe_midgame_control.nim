## Grade every midgame slot: spine, control-ish WRAM, free-walk span after unlock mash.
## Goal: past fourside40 — free deep-south slots or flag diffs vs free desert band.

import
  std/[os, strformat, strutils, algorithm],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  # Candidate control / mode / dialogue locks (hypothesis — probe diffs only).
  Watch = [
    0x8650, 0x8654, 0x4DBA, 0x5D60, 0x9875, 0x9876, 0x9877, 0x9878,
    0x9879, 0x987A, 0x987B, 0x987C, 0x9881, 0x9885, 0x9887, 0x99F2,
    0x89CA, 0x5E06, 0x5E07, 0x9670, 0x9671
  ]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc gradeStatic(path: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  try:
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  except CatchableError:
    return
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  let p0 = readU8(snes, PartySlot0)
  let p1 = readU8(snes, PartySlot1)
  let p2 = readU8(snes, PartySlot2)
  let p3 = readU8(snes, 0x988E)
  let money = readU16(snes, 0x9831)
  let fo = foursidePercent(snes)
  let be = belchPercent(snes)
  let wi = wintersPercent(snes)
  let ma = magicantPercent(snes)
  # Print mid/late candidates
  if p1 != 0 or p2 != 0 or money > 200 or py > 0x0800:
    var flags = ""
    for off in Watch:
      flags.add fmt" ${off:04X}={readU8(snes,off):02X}"
    echo fmt"{extractFilename(path)}: pos=(0x{px:04X},0x{py:04X}) party={p0:02X},{p1:02X},{p2:02X},{p3:02X} $={money} w={wi} b={be} f={fo} m={ma}{flags}"

proc walkSpan(path: string; frames = 2500): int =
  if not fileExists(path): return -1
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local t = frame() % 100
  if t < 12 then pad.press("A")
  elseif t < 20 then pad.press("B")
  elseif t < 45 then pad.press("Down")
  elseif t < 65 then pad.press("Right")
  elseif t < 80 then pad.press("Left")
  else pad.press("Up") end
end
""", "unlock")
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
  echo fmt"  walk span={result} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} end_fourside={foursidePercent(snes)} money={readU16(snes,0x9831)}"
  if result >= 200 and foursidePercent(snes) >= 40 and
      readU16(snes, WorldYBase + i) >= 0x1800:
    writeFile("bin/states/llm/midgame_deep.state", cast[string](serializeState(snes, c)))
    echo "  WROTE midgame_deep"

proc main() =
  echo "=== STATIC GRADES ==="
  var paths: seq[string]
  for kind, path in walkDir("bin/states"):
    if kind == pcFile and path.endsWith(".state"):
      paths.add path
  paths.sort()
  for p in paths:
    gradeStatic(p)
  echo "=== WALK SPANS (deep / free candidates) ==="
  for p in [
    "bin/states/slot4.state",
    "bin/states/llm/midgame_approach.state",
    "bin/states/slot75.state",
    "bin/states/slot73.state",
    "bin/states/slot77.state",
    "bin/states/slot130.state",
    "bin/states/slot72.state",
    "bin/states/slot78.state",
    "bin/states/slot79.state",
    "bin/states/slot83.state",
    "bin/states/battle_menu_healthy.state",
    "bin/states/llm/post_battle_midgame.state"
  ]:
    if fileExists(p):
      echo p
      discard walkSpan(p)

when isMainModule:
  main()
