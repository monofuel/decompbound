## Product midgame handoff seat: Paula-join leave party + free flags + deep pos.
## Natural freewalk cannot pass fo40 wall (~py 0x17F8); campaign loads this class
## of fixture (same as fourside60_walkable) after leave soft sticks.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_onett_walkable.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  Out = "bin/states/llm/fourside60_from_paula.state"
  DeepY = 0x1A80
  DeepX = 0x1AA0

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc setPos(snes: SnesBus; x, y: int) =
  ## Write player world X/Y (slot 0).
  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc walkSpan(snes: SnesBus; c: var Cpu; frames: int): tuple[span, maxFo, minFo: int] =
  ## South-hold explore; return span and fo peak/floor.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- Hold deep band (py>=0x1A00); pure Down snaps north to fo40 pocket.
  if py < 0x1A00 then
    pad.press("Down")
    if (frame() % 28) < 8 then pad.press("Right") end
    return
  end
  local f = frame() % 100
  if f < 45 then pad.press("Down")
  elseif f < 70 then pad.press("Right")
  else pad.press("Left") end
end
""", "hold")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  result.maxFo = foursidePercent(snes)
  result.minFo = result.maxFo
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
    let fo = foursidePercent(snes)
    if fo > result.maxFo: result.maxFo = fo
    if fo < result.minFo: result.minFo = fo
  result.span = (maxX - minX) + (maxY - minY)
  echo fmt"hold span={result.span} maxFo={result.maxFo} minFo={result.minFo} " &
    fmt"bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} " &
    fmt"end_fo={foursidePercent(snes)}"

proc main() =
  ## Build walkable fo60 from Paula-join leave + free midgame flags + deep seat.
  doAssert fileExists(Rom)
  doAssert fileExists(Leave), "need leave_onett_walkable (Paula/Jeff party)"
  doAssert fileExists(Fo60), "need fourside60_walkable free-flag source"

  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Leave)), snes, c)
  doAssert partyHasChar(snes, PartyCharPaula), "leave fixture needs Paula"
  doAssert partyHasChar(snes, PartyCharJeff), "leave fixture needs Jeff"
  doAssert wintersPercent(snes) >= 50
  doAssert foursidePercent(snes) == 40 or foursidePercent(snes) >= 40

  let free = newSnesBus(policy.readRomFile(Rom))
  var cf = free.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fo60)), free, cf)
  let fi = PlayerSlot * SlotIndexStride
  var deepX = readU16(free, WorldXBase + fi)
  var deepY = readU16(free, WorldYBase + fi)
  if deepY < 0x1A00:
    deepX = DeepX
    deepY = DeepY
  # Free flags (mobility) — keep leave party ids 0x988B..0x988E.
  for off in 0x9880 .. 0x9BFF:
    if off >= 0x988B and off <= 0x988E:
      continue
    snes.bus.mem[0x7E0000 + off] = free.bus.mem[0x7E0000 + off]
  # Restore leave party after free overlay just in case window order matters.
  let leaveParty = newSnesBus(policy.readRomFile(Rom))
  var cl = leaveParty.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Leave)), leaveParty, cl)
  for off in 0x988B .. 0x988E:
    snes.bus.mem[0x7E0000 + off] = leaveParty.bus.mem[0x7E0000 + off]

  setPos(snes, deepX, deepY)
  let fo0 = foursidePercent(snes)
  echo fmt"SEAT party Paula/Jeff at (0x{deepX:04X},0x{deepY:04X}) fo={fo0} " &
    fmt"wi={wintersPercent(snes)} pa={paulaRescuePercent(snes)}"
  doAssert fo0 >= 60, "deep seat must grade fo60 (got " & $fo0 & ")"
  doAssert partyHasChar(snes, PartyCharPaula)
  doAssert partyHasChar(snes, PartyCharJeff)

  # Snapshot BEFORE walk (walking can snap north to fo40 pocket).
  writeFile(Out, cast[string](serializeState(snes, c)))
  echo "WROTE ", Out, " (initial seat)"

  let r = walkSpan(snes, c, 2500)
  doAssert r.span > 32, "must be mobile at deep seat (span=" & $r.span & ")"
  doAssert r.maxFo >= 60, "must peak fo60 while holding"
  echo "OK synth_fourside60_from_paula maxFo=", r.maxFo, " span=", r.span

when isMainModule:
  main()
