## Probe west approach from giant_approach on several Y lanes to reach captain 50.
## Path dependence: west_pulse from (0x0900,0x0276) works; from giant y~0x0281 sticks.

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

proc runLane(path, name, pol: string; frames = 8000): int =
  if not fileExists(path):
    echo "SKIP ", path
    return 0
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua, "sk")
  loadChunk(L, pol, name)
  var maxCs = captainStrongPercent(snes)
  var minX = 0xFFFF
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START {name} cs={maxCs} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    let cs = captainStrongPercent(snes)
    if cs > maxCs:
      maxCs = cs
      echo fmt"  NEW cs={maxCs} f={f} pos=(0x{px:04X},0x{py:04X})"
    if maxCs >= 50:
      writeFile("bin/states/llm/captain_west.state", cast[string](serializeState(snes, cpu)))
      echo "WROTE captain_west"
      break
  echo fmt"FINAL {name} max_cs={maxCs} minX=0x{minX:04X} end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  maxCs

proc lanePol(targetY: int): string =
  ## Seat at x~0x0910 on targetY, then west-pulse (proven for cs 50).
  fmt"""
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local ty = {targetY}
  -- Phase 1: seat east of wall (px > 0x0908) and match lane Y.
  if px > 0x0908 or (px > 0x08F8 and math.abs(py - ty) > 0x10) then
    if math.abs(py - ty) > 8 then
      if py > ty then pad.press("Up") else pad.press("Down") end
      if px > 0x0920 then pad.press("Left") end
      return
    end
    if px > 0x0908 then
      pad.press("Left")
      return
    end
  end
  -- Phase 2: west pulse toward 0x0890 (cs 50).
  if px > 0x0888 then
    pad.press("Left")
    if (frame() % 32) < 10 then pad.press("Up") end
    if (frame() % 32) >= 24 then pad.press("Down") end
    return
  end
  -- Hold / south for cs 60.
  if py < 0x02A0 then pad.press("Down") else pad.press("Left") end
end
"""

proc twoPhaseSeat(): string =
  ## Explicit: walkTo seat (0x0900,0x0258) then west. Uses walkTo if present.
  """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- Retreat from wall pocket first.
  if px >= 0x08D8 and px <= 0x08F8 then
    pad.press("Right")
    if (frame() % 40) < 12 then pad.press("Up") end
    return
  end
  -- Seat on known-good lane before deep west.
  if px > 0x0910 or py > 0x0270 or py < 0x0248 then
    if walkTo then
      walkTo(0x0910, 0x0258)
    else
      if py > 0x0260 then pad.press("Up")
      elseif py < 0x0248 then pad.press("Down")
      elseif px > 0x0910 then pad.press("Left")
      else pad.press("Right") end
    end
    return
  end
  -- From seat: pure west pulse.
  if px > 0x0888 then
    pad.press("Left")
    if (frame() % 28) < 8 then pad.press("Up") end
    if (frame() % 28) >= 20 then pad.press("Down") end
    return
  end
  if py < 0x02A0 then pad.press("Down") else pad.press("Left") end
end
"""

proc main() =
  let giant = "bin/states/llm/giant_approach.state"
  let cap = "bin/states/llm/captain_approach.state"
  discard runLane(cap, "cap_west_pulse", """
function update()
  if escapeMenu() then return end
  pad.press("Left")
  if (frame() % 32) < 10 then pad.press("Up") end
  if (frame() % 32) >= 24 then pad.press("Down") end
end
""")
  for ty in [0x0240, 0x0250, 0x0258, 0x0260, 0x0268, 0x0270, 0x0278, 0x0280]:
    discard runLane(giant, fmt"lane_y{ty:04X}", lanePol(ty), 6000)
  discard runLane(giant, "two_phase_seat", twoPhaseSeat(), 10000)
  if fileExists(cap):
    discard runLane(cap, "two_phase_from_cap", twoPhaseSeat(), 6000)

when isMainModule:
  main()
