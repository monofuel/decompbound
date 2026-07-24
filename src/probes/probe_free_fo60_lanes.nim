## Free midgame flags + deep coords free-walk: find walkable lane into fo60.
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Free = "bin/states/slot4.state"
const Mid = "bin/states/llm/midgame_approach.state"
const Out = "bin/states/llm/fourside60_freewalk.state"
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
const South = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  pad.press("Down")
  local f = frame() % 40
  if f < 10 then pad.press("Right") elseif f < 20 then pad.press("Left") end
end
"""
proc tryLane(x, y: int; frames: int): tuple[maxFo, maxPy, span: int; walkable: bool] =
  let path = if fileExists(Free): Free else: Mid
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  setPos(snes, x, y)
  let fo0 = foursidePercent(snes)
  let i = PlayerSlot * SlotIndexStride
  var minX = x
  var maxX = x
  var minY = y
  var maxY = y
  var maxFo = fo0
  var maxPy = y
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, South, "w")
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    let fo = foursidePercent(snes)
    if fo > maxFo: maxFo = fo
    if py > maxPy: maxPy = py
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  let span = (maxX-minX)+(maxY-minY)
  let walkable = span > 200 and maxFo >= 60
  echo fmt"lane (0x{x:04X},0x{y:04X}) fo0={fo0} max_fo={maxFo} max_py=0x{maxPy:04X} span={span} walkable={walkable}"
  if walkable and maxFo >= 60:
    writeFile(Out, cast[string](serializeState(snes, c)))
    echo "WROTE ", Out
  result = (maxFo, maxPy, span, walkable)

proc main() =
  doAssert fileExists(Rom)
  # Free control at proven deep coords
  for y in [0x1A00, 0x1B00, 0x1C00, 0x2000, 0x23EB]:
    for x in [0x0F8A, 0x1200, 0x1500, 0x1AA5, 0x0DA0]:
      let r = tryLane(x, y, 2500)
      if r.walkable: break
  # Product free-walk from fo60 fixture with AgentFoursideApproach
  if fileExists("bin/states/llm/fourside60_walkable.state"):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/fourside60_walkable.state")), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox(); policy.setupPolicyApi(L, ctx)
    loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
      WalkToSkillLua & "\n" & NavSkillLua & "\n" & IntentNavSkillLua, "sk")
    loadChunk(L, AgentFoursideApproachPolicy, "fo")
    var maxFo = foursidePercent(snes)
    var minFo = maxFo
    for f in 1 .. 4000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let fo = foursidePercent(snes)
      if fo > maxFo: maxFo = fo
      if fo < minFo: minFo = fo
    echo fmt"AgentFourside free-walk hold max_fo={maxFo} min_fo={minFo}"
    doAssert maxFo >= 60, "fo60 free-walk product must hold peak 60"
  echo "OK probe_free_fo60_lanes"

main()
