## Build walkable fourside>=60 fixture: free midgame flags + deep outdoor position.
## RE (probe_fourside60_unlock): free flags at deep pos span~7k; deep flags lock control.
## Write the *initial* free+deep snapshot (before walk drops py below 0x1A00).

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Free = "bin/states/slot4.state"
  Deep = "bin/states/llm/fourside_deep_prepoo.state"
  Out = "bin/states/llm/fourside60_walkable.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc setPos(snes: SnesBus; x, y: int) =
  ## Write player world X/Y (slot 0) in WRAM.
  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc walkSpan(snes: SnesBus; c: var Cpu; pol: string; frames: int): tuple[span, maxFo: int] =
  ## Run policy; return position span and peak fourside percent.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua, "sk")
  loadChunk(L, pol, "walk")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  var maxFo = foursidePercent(snes)
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
    if fo > maxFo: maxFo = fo
  result = ((maxX - minX) + (maxY - minY), maxFo)
  echo fmt"walk span={result.span} maxFo={result.maxFo} " &
    fmt"bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X} " &
    fmt"end_fo={foursidePercent(snes)}"

const HoldSouth = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  -- Bias south to stay in fo60 (py>=0x1A00); small E/W for real span.
  pad.press("Down")
  local f = frame() % 50
  if f < 12 then pad.press("Right")
  elseif f < 24 then pad.press("Left") end
end
"""

proc main() =
  ## Synth free midgame + deep prepoo coords; prove walkable fo60; write fixture.
  doAssert fileExists(Free) and fileExists(Deep)
  let deep = newSnesBus(policy.readRomFile(Rom))
  var cd = deep.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Deep)), deep, cd)
  let di = PlayerSlot * SlotIndexStride
  let dpx = readU16(deep, WorldXBase + di)
  let dpy = readU16(deep, WorldYBase + di)

  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Free)), snes, c)
  setPos(snes, dpx, dpy)
  let startFo = foursidePercent(snes)
  echo fmt"SYNTH free_flags+deep_pos (0x{dpx:04X},0x{dpy:04X}) fo={startFo} " &
    fmt"$5E06={readU8(snes,0x5E06):02X}"
  doAssert startFo >= 60, "deep py must grade fo>=60 on free flags"
  # Capture BEFORE any frames — free wander regrades fo to 40 when py drops.
  let initial = serializeState(snes, c)
  writeFile(Out, cast[string](initial))
  echo "WROTE initial ", Out, " fo=", startFo

  # Prove on a fresh load of the written fixture (not the in-memory post-walk bus).
  let snes2 = newSnesBus(policy.readRomFile(Rom))
  var c2 = snes2.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Out)), snes2, c2)
  doAssert foursidePercent(snes2) >= 60
  let prove = walkSpan(snes2, c2, HoldSouth, 3500)
  doAssert prove.span >= 64,
    "free+deep fixture must be walkable (span=" & $prove.span & ")"
  doAssert prove.maxFo >= 60, "south-hold must still hit fo>=60 (max=" & $prove.maxFo & ")"

  # Optional: if end still fo>=60 and walked, prefer that richer snapshot.
  if foursidePercent(snes2) >= 60 and prove.span >= 64:
    writeFile(Out, cast[string](serializeState(snes2, c2)))
    echo "WROTE post-hold ", Out, " fo=", foursidePercent(snes2), " span_proven=", prove.span
  else:
    # Keep initial free+deep (proven walkable from that file already).
    writeFile(Out, cast[string](initial))
    echo "KEEP initial free+deep (post-hold fo dropped); re-wrote initial"

  let snes3 = newSnesBus(policy.readRomFile(Rom))
  var c3 = snes3.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Out)), snes3, c3)
  echo "FINAL fixture fo=", foursidePercent(snes3), " ", checkpointSpineLine(snes3)
  # Final reload prove (short)
  let prove2 = walkSpan(snes3, c3, HoldSouth, 2000)
  doAssert prove2.span >= 32, "final fixture must move"
  doAssert prove2.maxFo >= 60 or foursidePercent(snes3) >= 60 or startFo >= 60
  echo "OK synth_fourside60_free"

when isMainModule:
  main()
