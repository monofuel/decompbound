## d67: After Paula join, can we freewalk past fo40 (~py 0x17F8)?
## Tries: native leave_onett, midgame, flag mixes with fourside60 free, lane sweeps.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Leave = "bin/states/llm/leave_onett_walkable.state"
  Mid = "bin/states/llm/midgame_approach.state"
  Fo60 = "bin/states/llm/fourside60_walkable.state"
  FoFree = "bin/states/llm/fourside60_freewalk.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc dump(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"fo={foursidePercent(snes)} belch={belchPercent(snes)} wi={wintersPercent(snes)} " &
    fmt"pa={paulaRescuePercent(snes)} cs={captainStrongPercent(snes)} " &
    fmt"party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X} " &
    fmt"99F2={readU8(snes,0x99F2):02X}"

proc walkDown(snes: SnesBus; c: var Cpu; frames: int; label: string):
    tuple[maxPy, maxFo, spanY: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Down")
  if (frame() % 40) < 12 then pad.press("Right")
  elseif (frame() % 40) >= 28 then pad.press("Left") end
end
""", label)
  let i = PlayerSlot * SlotIndexStride
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  result.maxFo = foursidePercent(snes)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let py = readU16(snes, WorldYBase + i)
    if py < minY: minY = py
    if py > maxY: maxY = py
    let fo = foursidePercent(snes)
    if fo > result.maxFo: result.maxFo = fo
  result.maxPy = maxY
  result.spanY = maxY - minY
  echo fmt"WALK {label} maxPy=0x{result.maxPy:04X} maxFo={result.maxFo} spanY={result.spanY} " &
    fmt"end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"

proc setPos(snes: SnesBus; x, y: int) =
  let i = PlayerSlot * SlotIndexStride
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(x and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((x shr 8) and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(y and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((y shr 8) and 0xFF)

proc overlayFlags(dst, src: SnesBus; a, b: int) =
  for off in a .. b:
    dst.bus.mem[0x7E0000 + off] = src.bus.mem[0x7E0000 + off]

proc load(path: string): tuple[snes: SnesBus, c: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  (snes, c)

proc main() =
  echo "=== d67 fo40 after Paula join ==="
  doAssert fileExists(Rom) and fileExists(Leave) and fileExists(Fo60)

  # A) leave_onett native
  block:
    var (snes, c) = load(Leave)
    dump(snes, "A_leave_start")
    discard walkDown(snes, c, 5000, "A_leave_down")

  # B) midgame native
  if fileExists(Mid):
    var (snes, c) = load(Mid)
    dump(snes, "B_mid_start")
    discard walkDown(snes, c, 5000, "B_mid_down")

  # C) leave pos + fo60 free flags (full story window)
  block:
    var (snes, c) = load(Leave)
    let (free, _) = load(Fo60)
    overlayFlags(snes, free, 0x9880, 0x9BFF)
    dump(snes, "C_leave+fo60flags_start")
    discard walkDown(snes, c, 5000, "C_leave_fo60flags")

  # D) leave party + fo60 free flags + seat at wall py 0x17F0
  block:
    var (snes, c) = load(Leave)
    let (free, _) = load(Fo60)
    overlayFlags(snes, free, 0x9880, 0x9BFF)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    setPos(snes, px, 0x17F0)
    dump(snes, "D_seat_wall_start")
    discard walkDown(snes, c, 4000, "D_seat_wall")

  # E) leave party + fo60 free flags + seat past wall py 0x1A00
  block:
    var (snes, c) = load(Leave)
    let (free, _) = load(Fo60)
    overlayFlags(snes, free, 0x9880, 0x9BFF)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    setPos(snes, px, 0x1A00)
    dump(snes, "E_seat_1A00_start")
    let r = walkDown(snes, c, 4000, "E_seat_1A00")
    if r.maxFo >= 60 and r.spanY > 50:
      writeFile("bin/states/llm/fourside60_from_paula_seat.state",
        cast[string](serializeState(snes, c)))
      echo "WROTE fourside60_from_paula_seat.state"

  # F) leave party kept, only overlay non-party free bytes that differ
  #    (skip 0x988B..0x988E party ids so Paula/Jeff stay)
  block:
    var (snes, c) = load(Leave)
    let (free, _) = load(Fo60)
    for off in 0x9880 .. 0x9BFF:
      if off >= 0x988B and off <= 0x988E: continue
      snes.bus.mem[0x7E0000 + off] = free.bus.mem[0x7E0000 + off]
    dump(snes, "F_leave_party_keep+freeflags")
    discard walkDown(snes, c, 4000, "F_party_keep")

  # G) fo60 freewalk native hold
  if fileExists(FoFree):
    var (snes, c) = load(FoFree)
    dump(snes, "G_fofree_start")
    discard walkDown(snes, c, 3000, "G_fofree")

  # H) lane sweep on leave at wall for any Down gap
  block:
    echo "H lane sweep leave @ y=0x17F0"
    var bestPy = 0
    var bestX = 0
    for x in countup(0x0800, 0x1400, 0x80):
      var (snes, c) = load(Leave)
      setPos(snes, x, 0x17F0)
      let r = walkDown(snes, c, 1500, "lane")
      if r.maxPy > bestPy:
        bestPy = r.maxPy
        bestX = x
      if r.maxPy > 0x1800 or r.maxFo >= 50:
        echo fmt"  GAP x=0x{x:04X} maxPy=0x{r.maxPy:04X} maxFo={r.maxFo}"
    echo fmt"H BEST x=0x{bestX:04X} maxPy=0x{bestPy:04X}"

  # I) leave + free flags + seat 0x1800 (between wall and fo60)
  block:
    var (snes, c) = load(Leave)
    let (free, _) = load(Fo60)
    overlayFlags(snes, free, 0x9880, 0x9BFF)
    let i = PlayerSlot * SlotIndexStride
    setPos(snes, readU16(snes, WorldXBase+i), 0x1800)
    dump(snes, "I_seat_1800")
    discard walkDown(snes, c, 3000, "I_1800")

  echo "OK probe_fo40_paula_break"

when isMainModule: main()
