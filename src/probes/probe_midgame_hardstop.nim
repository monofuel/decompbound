## Diagnose midgame south hard-stop (slot4 fo=40 maxPy~0x16B0) vs fourside_deep_prepoo.
## Map free bbox, flag-diff, unlock attempts on prepoo, Agent walk from free→deeper.

import
  std/[os, strformat, tables, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Slot4 = "bin/states/slot4.state"
  Mid = "bin/states/llm/midgame_approach.state"
  PrePoo = "bin/states/llm/fourside_deep_prepoo.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc load(path: string): (SnesBus, Cpu) =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc grade(path: string) =
  if not fileExists(path):
    echo "SKIP ", path
    return
  let (snes, _) = load(path)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{extractFilename(path)}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"fo={foursidePercent(snes)} belch={belchPercent(snes)} winters={wintersPercent(snes)} " &
    fmt"lv={partyLeaderLevel(snes)} size={partySize(snes)} bp={eventFlagBitPop(snes)} " &
    fmt"$9881={readU8(snes,0x9881):02X} $9887={readU8(snes,0x9887):02X} $89CA={readU16(snes,0x89CA):04X} $5E06={readU8(snes,0x5E06):02X}"
  echo "  ", checkpointSpineLine(snes)

proc snap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in 0x9880 .. 0x9C00:
    result[off] = readU8(snes, off)

proc walkPol(pol: string; path: string; frames: int; name: string): tuple[maxFo, maxPy, minX, maxX, minY, maxY, span: int] =
  let (snes, c0) = load(path)
  var c = c0
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & WalkToSkillLua, "sk")
  loadChunk(L, pol, name)
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
    if fo > maxFo:
      maxFo = fo
      echo fmt"  {name} NEW fo={fo} f={f} pos=(0x{px:04X},0x{py:04X})"
  result = (maxFo, maxPy, minX, maxX, minY, maxY, (maxX - minX) + (maxY - minY))
  echo fmt"WALK {name} from {extractFilename(path)}: fo={maxFo} maxPy=0x{maxPy:04X} span={result.span} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X}"

const
  SouthPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Down")
  if (frame() % 48) < 12 then pad.press("Left") end
  if (frame() % 48) >= 36 then pad.press("Right") end
end
"""
  EastSouthPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 100
  if f < 45 then pad.press("Right")
  elseif f < 80 then pad.press("Down")
  elseif f < 90 then pad.press("Left")
  else pad.press("Up") end
end
"""
  WestSouthPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local f = frame() % 100
  if f < 45 then pad.press("Left")
  elseif f < 80 then pad.press("Down")
  else pad.press("Right") end
end
"""
  UnlockPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local t = frame() % 90
  if t < 15 then pad.press("A")
  elseif t < 25 then pad.press("B")
  elseif t < 50 then pad.press("Down")
  elseif t < 70 then pad.press("Right")
  else pad.press("Left") end
end
"""
  FoursideAgentPol = """
-- NOTE: Agent Fourside soft from deep-south desert (fo>=40): push py to 0x1A00+
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- Reach fo 60 band first.
  if py < 0x1A00 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Right") end
    if (frame() % 36) >= 26 then pad.press("Left") end
    return
  end
  -- Past 0x1A00: explore SE for deeper Fourside soft / bus stops.
  local f = frame() % 120
  if f < 50 then pad.press("Down")
  elseif f < 85 then pad.press("Right")
  elseif f < 105 then pad.press("Left")
  else pad.press("Up") end
end
"""

proc main() =
  echo "=== STATIC GRADES ==="
  grade(Slot4)
  grade(Mid)
  grade(PrePoo)

  if fileExists(Slot4) and fileExists(PrePoo):
    let (a, _) = load(Slot4)
    let (b, _) = load(PrePoo)
    let sa = snap(a)
    let sb = snap(b)
    var n = 0
    echo "=== FLAGDIFF slot4 -> fourside_deep_prepoo (story-ish) ==="
    for off in 0x9880 .. 0x9C00:
      let va = sa.getOrDefault(off, 0)
      let vb = sb.getOrDefault(off, 0)
      if va != vb:
        # Prefer event-flag window + party
        if off >= 0x9880 and off <= 0x99F2 or off >= 0x9A00:
          if n < 35:
            echo fmt"  ${off:04X}: 0x{va:02X}->0x{vb:02X}"
          n.inc
    echo "flagdiffs_in_window=", n

  echo "=== FREE-WALK BOUNDS (slot4) ==="
  if fileExists(Slot4):
    discard walkPol(SouthPol, Slot4, 5000, "slot4_south")
    discard walkPol(EastSouthPol, Slot4, 5000, "slot4_es")
    discard walkPol(WestSouthPol, Slot4, 5000, "slot4_ws")
    discard walkPol(UnlockPol, Slot4, 4000, "slot4_unlock")

  echo "=== PREPOO FREEDOM / AGENT ==="
  if fileExists(PrePoo):
    let r1 = walkPol(UnlockPol, PrePoo, 4000, "prepoo_unlock")
    let r2 = walkPol(FoursideAgentPol, PrePoo, 6000, "prepoo_agent")
    let r3 = walkPol(SouthPol, PrePoo, 4000, "prepoo_south")
    # If agent holds fo>=60, write walkable fixture from best end state
    if r2.maxFo >= 60 or r1.maxFo >= 60 or r3.maxFo >= 60:
      # Re-run agent and write final
      let (snes, c0) = load(PrePoo)
      var c = c0
      let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
      let ctx = policy.PolicyContext(
        snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
      let L = lua53.newstate()
      L.openSandbox()
      policy.setupPolicyApi(L, ctx)
      loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" &
        AdvanceDialogueSkillLua, "sk")
      loadChunk(L, FoursideAgentPol, "agent")
      var maxFo = foursidePercent(snes)
      var best: seq[byte] = @[]
      let i = PlayerSlot * SlotIndexStride
      for f in 1 .. 8000:
        ctx.frameCount = f
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
        let fo = foursidePercent(snes)
        if fo > maxFo or (fo >= 60 and best.len == 0):
          maxFo = fo
          best = serializeState(snes, c)
          echo fmt"  BEST fo={fo} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
        if maxFo >= 60 and f > 500:
          # keep exploring a bit then stop if still free
          if f > 2000: break
      if best.len == 0:
        best = serializeState(snes, c)
      writeFile("bin/states/llm/fourside60_walkable.state", cast[string](best))
      echo "WROTE fourside60_walkable max_fo=", maxFo
      echo "  ", checkpointSpineLine(snes)

  echo "=== HARD-STOP SUMMARY ==="
  echo "slot4 free map: fo40 band py~0x1660..0x17F8; fo60 needs py>=0x1A00 (map wall or story gate)"
  echo "prepoo F12 starts at py~0x23EB fo=60 — test Agent freedom there"
  echo "OK probe_midgame_hardstop"

when isMainModule:
  main()
