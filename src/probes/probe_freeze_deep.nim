## Deep freeze RE: pure pad on free states; live post-pokey copy-fixture regions until AgentHome moves.
import std/[os, strformat, strutils], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, scene, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1
proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc padDelta(snes: SnesBus; c: var Cpu; bit: uint16; frames: int): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let x0 = readU16(snes, WorldXBase+i)
  let y0 = readU16(snes, WorldYBase+i)
  for _ in 1 .. frames:
    snes.joy1 = bit
    policy.stepOneFrame(snes, c, img)
  result = abs(readU16(snes, WorldXBase+i) - x0) + abs(readU16(snes, WorldYBase+i) - y0)

proc agentHomeDelta(snes: SnesBus; c: var Cpu; frames: int): tuple[d, maxK: int, pos: string] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentHomePolicy, "home")
  let i = PlayerSlot * SlotIndexStride
  let x0 = readU16(snes, WorldXBase+i)
  let y0 = readU16(snes, WorldYBase+i)
  var maxK = pokeyKnockPercent(snes)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let k = pokeyKnockPercent(snes)
    if k > maxK: maxK = k
  let x1 = readU16(snes, WorldXBase+i)
  let y1 = readU16(snes, WorldYBase+i)
  result = (abs(x1.int - x0.int) + abs(y1.int - y0.int), maxK, fmt"(0x{x1:04X},0x{y1:04X})")

proc runLive(): tuple[snes: SnesBus, c: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/onett_start.state")), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox(); policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentOutdoorPolicy, "out")
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    if pokeyPercent(snes) >= 100:
      for e in 1 .. 200:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
        if readU8(snes, 0x8650) == 0xFF and readU8(snes, 0x8654) == 0xFF:
          break
      break
  result = (snes, c)

proc main() =
  # Baseline free states
  for path in ["bin/states/llm/onett_start.state", "bin/states/llm/pokey_done.state", "bin/states/llm/pokey_free.state"]:
    if not fileExists(path): continue
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    let dR = padDelta(snes, c, 0x0100, 40)
    # reload for Left
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    let dL = padDelta(snes, c, 0x0200, 40)
    echo fmt"PAD {path.splitPath.tail} Right d={dR} Left d={dL} win1={readU8(snes,0x8654):#04x} $5D52={readU8(snes,0x5D52):#04x}"

  # Fixture AgentHome short
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), snes, c)
    let r = agentHomeDelta(snes, c, 600)
    echo fmt"FIXTURE AgentHome 600f d={r.d} maxK={r.maxK} pos={r.pos}"

  # Live baseline AgentHome short
  block:
    var t = runLive()
    echo fmt"LIVE pad Right d={padDelta(t.snes, t.c, 0x0100, 40)} win1={readU8(t.snes,0x8654):#04x}"
  block:
    var t = runLive()
    let r = agentHomeDelta(t.snes, t.c, 800)
    echo fmt"LIVE AgentHome 800f d={r.d} maxK={r.maxK} pos={r.pos}"

  # Live: try longer dialogue drain with A only after pokey, then AgentHome
  block:
    var t = runLive()
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for i in 1 .. 300:
      t.snes.joy1 = if (i mod 8) < 3: 0x0080'u16 else: 0
      policy.stepOneFrame(t.snes, t.c, img)
    echo fmt"LIVE after A-pulse win1={readU8(t.snes,0x8654):#04x} pad d={padDelta(t.snes, t.c, 0x0200, 40)}"
    let r = agentHomeDelta(t.snes, t.c, 800)
    echo fmt"LIVE after A-pulse AgentHome d={r.d} maxK={r.maxK} pos={r.pos}"

  # Live: B cancel pulses
  block:
    var t = runLive()
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for i in 1 .. 60:
      t.snes.joy1 = 0x8000  # B?
      policy.stepOneFrame(t.snes, t.c, img)
      t.snes.joy1 = 0
      policy.stepOneFrame(t.snes, t.c, img)
    echo fmt"LIVE after B-pulse pad d={padDelta(t.snes, t.c, 0x0200, 40)}"

  # Copy large WRAM ranges from fixture onto live, keep player pos
  let fix = newSnesBus(policy.readRomFile(Rom))
  var fc = fix.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), fix, fc)
  let ranges = [
    (0x0000, 0x0100), (0x0A00, 0x0E00), (0x1A00, 0x1C00),
    (0x4A00, 0x4E00), (0x5D00, 0x5F00), (0x8600, 0x8A00),
    (0x9600, 0x9C00), (0x9E00, 0xA000),
  ]
  for (a, b) in ranges:
    var t = runLive()
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(t.snes, WorldXBase+i)
    let py = readU16(t.snes, WorldYBase+i)
    for off in a ..< b:
      if off == WorldXBase+i or off == WorldXBase+i+1 or off == WorldYBase+i or off == WorldYBase+i+1:
        continue
      t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    # restore pos
    t.snes.bus.mem[0x7E0000 + WorldXBase+i] = uint8(px and 0xFF)
    t.snes.bus.mem[0x7E0000 + WorldXBase+i+1] = uint8(px shr 8)
    t.snes.bus.mem[0x7E0000 + WorldYBase+i] = uint8(py and 0xFF)
    t.snes.bus.mem[0x7E0000 + WorldYBase+i+1] = uint8(py shr 8)
    let r = agentHomeDelta(t.snes, t.c, 400)
    if r.d > 4 or r.maxK > 10:
      echo fmt"UNLOCK range ${a:04X}..${b:04X} d={r.d} maxK={r.maxK} pos={r.pos}"
    else:
      echo fmt"no range ${a:04X}..${b:04X} d={r.d} maxK={r.maxK}"

  # Full WRAM copy except pos from fixture
  block:
    var t = runLive()
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(t.snes, WorldXBase+i)
    let py = readU16(t.snes, WorldYBase+i)
    for off in 0 .. 0x1FFFF:
      t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    t.snes.bus.mem[0x7E0000 + WorldXBase+i] = uint8(px and 0xFF)
    t.snes.bus.mem[0x7E0000 + WorldXBase+i+1] = uint8(px shr 8)
    t.snes.bus.mem[0x7E0000 + WorldYBase+i] = uint8(py and 0xFF)
    t.snes.bus.mem[0x7E0000 + WorldYBase+i+1] = uint8(py shr 8)
    let r = agentHomeDelta(t.snes, t.c, 600)
    echo fmt"FULL WRAM copy keep pos d={r.d} maxK={r.maxK} pos={r.pos}"

  echo "OK probe_freeze_deep"

main()
