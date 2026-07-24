## After live pokey100: try unlock candidates until Right pad moves; then AgentHome.
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

proc moveDelta(snes: SnesBus; c: var Cpu; bit: uint16; frames: int): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let x0 = readU16(snes, WorldXBase+i)
  let y0 = readU16(snes, WorldYBase+i)
  for _ in 1 .. frames:
    snes.joy1 = bit
    policy.stepOneFrame(snes, c, img)
  result = abs(readU16(snes, WorldXBase+i) - x0) + abs(readU16(snes, WorldYBase+i) - y0)

proc runToLivePokey(): tuple[snes: SnesBus, c: Cpu, L: lua53.PState, ctx: policy.PolicyContext, skills: string] =
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
      for e in 1 .. 150:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c, L, ctx, skills)

proc main() =
  # Baseline fixture move after dialogue drain via A
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), snes, c)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    # drain win1 with A
    for _ in 1 .. 200:
      snes.joy1 = 0x0080
      policy.stepOneFrame(snes, c, img)
      if readU8(snes, 0x8654) == 0xFF: break
    let d = moveDelta(snes, c, 0x0100, 40)
    echo fmt"FIXTURE after drain win1={readU8(snes,0x8654):#04x} Right d={d} $5D52={readU8(snes,0x5D52):#04x}"

  var t = runToLivePokey()
  echo fmt"LIVE baseline $5D52={readU8(t.snes,0x5D52):#04x} win1={readU8(t.snes,0x8654):#04x} Right d={moveDelta(t.snes, t.c, 0x0100, 40)}"

  # Try poking individual bytes from fixture values
  let fix = newSnesBus(policy.readRomFile(Rom))
  var fc = fix.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), fix, fc)

  # Candidates that differed
  let cands = [0x5D52, 0x5D62, 0x0B56, 0x0B58, 0x0B5A, 0x0B62, 0x9652, 0x9654, 0x9656,
               0x96C5, 0x9875, 0x9876, 0x9877, 0x9879, 0x987A, 0x987D, 0x9A0B]
  for off in cands:
    # fresh live each try
    t = runToLivePokey()
    let before = readU8(t.snes, off)
    let want = readU8(fix, off)
    if before == want: continue
    t.snes.bus.mem[0x7E0000 + off] = uint8(want)
    let d = moveDelta(t.snes, t.c, 0x0100, 40)
    if d > 2:
      echo fmt"UNLOCK ${off:04X} {before:#04x}->{want:#04x} Right d={d}"
    else:
      echo fmt"no   ${off:04X} {before:#04x}->{want:#04x} d={d}"

  # Also try copying whole $5D00-$5D80 from fixture
  t = runToLivePokey()
  for off in 0x5D00 .. 0x5D7F:
    t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
  echo fmt"copy $5D00..5D7F Right d={moveDelta(t.snes, t.c, 0x0100, 40)}"

  # copy entity state $0B00-$0C00 except player pos
  t = runToLivePokey()
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(t.snes, WorldXBase+i)
  let py = readU16(t.snes, WorldYBase+i)
  for off in 0x0B00 .. 0x0CFF:
    if off == WorldXBase+i or off == WorldXBase+i+1 or off == WorldYBase+i or off == WorldYBase+i+1:
      continue
    t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
  echo fmt"copy entity state keep pos Right d={moveDelta(t.snes, t.c, 0x0100, 40)} pos=(0x{px:04X},0x{py:04X})"

  # Full free movement test: copy $5D52=1 only and home
  t = runToLivePokey()
  t.snes.bus.mem[0x7E0000 + 0x5D52] = 0x01
  loadChunk(t.L, t.skills, "sk")
  loadChunk(t.L, AgentHomePolicy, "home")
  var maxK = pokeyKnockPercent(t.snes)
  for f in 1 .. 12000:
    t.ctx.frameCount = f
    discard policy.runPolicyFrame(t.L, t.ctx)
    t.snes.joy1 = t.ctx.joy1
    policy.stepOneFrame(t.snes, t.c, t.ctx.frameImage)
    let k = pokeyKnockPercent(t.snes)
    if k > maxK: maxK = k
    if maxK >= 80: break
  echo "home after $5D52=1 max_knock=", maxK, " room=", currentRoomLabel(t.snes)
  echo "OK probe_unlock_live_pokey"
main()
