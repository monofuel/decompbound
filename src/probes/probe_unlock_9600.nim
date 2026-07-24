## Copy $9600-$9C00 from pokey_done onto live post-talk; try AgentHome + direction pads.
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
      for e in 1 .. 150:
        ctx.frameCount = f+e
        discard policy.runPolicyFrame(L, ctx)
        snes.joy1 = ctx.joy1
        policy.stepOneFrame(snes, c, img)
      break
  result = (snes, c)

proc padD(snes: SnesBus; c: var Cpu; bit: uint16; n: int): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let x0 = readU16(snes, WorldXBase+i); let y0 = readU16(snes, WorldYBase+i)
  for _ in 1 .. n:
    snes.joy1 = bit
    policy.stepOneFrame(snes, c, img)
  abs(readU16(snes, WorldXBase+i).int - x0.int) + abs(readU16(snes, WorldYBase+i).int - y0.int)

proc main() =
  let fix = newSnesBus(policy.readRomFile(Rom))
  var fc = fix.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), fix, fc)

  # Diff $9600..$9C00
  var diffs: seq[string]
  for off in 0x9600 .. 0x9BFF:
    let lv = 0 # filled later
    discard lv
  var t0 = runLive()
  echo "LIVE baseline pads R/L/D/U:"
  for (name, bit) in [("R", 0x0100'u16), ("L", 0x0200'u16), ("D", 0x0400'u16), ("U", 0x0800'u16)]:
    t0 = runLive()
    echo fmt"  {name} d={padD(t0.snes, t0.c, bit, 60)}"

  # After copy 9600
  t0 = runLive()
  var nDiff = 0
  for off in 0x9600 .. 0x9BFF:
    let a = t0.snes.bus.mem[0x7E0000 + off]
    let b = fix.bus.mem[0x7E0000 + off]
    if a != b:
      nDiff.inc
      if nDiff <= 40:
        echo fmt"DIFF ${off:04X} live={a:#04x} fix={b:#04x}"
      t0.snes.bus.mem[0x7E0000 + off] = b
  echo "copied ", nDiff, " bytes in $9600..$9BFF"
  echo "after copy pads:"
  block:
    let snes = t0.snes
    var c = t0.c
    # need re-run copy for each pad test
  for (name, bit) in [("R", 0x0100'u16), ("L", 0x0200'u16), ("D", 0x0400'u16), ("U", 0x0800'u16)]:
    var t = runLive()
    for off in 0x9600 .. 0x9BFF:
      t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    echo fmt"  {name} d={padD(t.snes, t.c, bit, 60)}"

  # Full AgentHome after copy
  block:
    var t = runLive()
    for off in 0x9600 .. 0x9BFF:
      t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(snes: t.snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox(); policy.setupPolicyApi(L, ctx)
    L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
    L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
    let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
      NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
    loadChunk(L, skills, "sk")
    loadChunk(L, AgentHomePolicy, "home")
    var maxK = pokeyKnockPercent(t.snes)
    let i = PlayerSlot * SlotIndexStride
    for f in 1 .. 10000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      t.snes.joy1 = ctx.joy1
      policy.stepOneFrame(t.snes, t.c, img)
      let k = pokeyKnockPercent(t.snes)
      if k > maxK: maxK = k
      if f mod 1500 == 0:
        echo fmt"home f={f} pos=(0x{readU16(t.snes,WorldXBase+i):04X},0x{readU16(t.snes,WorldYBase+i):04X}) maxK={maxK}"
      if maxK >= 80: break
    echo "AgentHome after $9600 copy maxK=", maxK

  # Binary search: which subrange of 9600 unlocks Left/Down
  let subranges = [
    (0x9600, 0x9700), (0x9700, 0x9800), (0x9800, 0x9900),
    (0x9900, 0x9A00), (0x9A00, 0x9B00), (0x9B00, 0x9C00),
  ]
  for (a, b) in subranges:
    var t = runLive()
    for off in a ..< b:
      t.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    let dL = padD(t.snes, t.c, 0x0200, 60)
    var t2 = runLive()
    for off in a ..< b:
      t2.snes.bus.mem[0x7E0000 + off] = fix.bus.mem[0x7E0000 + off]
    let dD = padD(t2.snes, t2.c, 0x0400, 60)
    echo fmt"sub ${a:04X}..${b:04X} Left d={dL} Down d={dD}"

  # Also: reopen talk then advance like fixture — retalk Pokey with AgentOutdoor briefly?
  block:
    var t = runLive()
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(snes: t.snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox(); policy.setupPolicyApi(L, ctx)
    L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
    L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
    let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" &
      NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
    loadChunk(L, skills, "sk")
    # force talk only
    loadChunk(L, """
function update()
  if advanceDialogue and advanceDialogue() then return end
  if talk and talk("pokey") then return end
  pad.press("A")
end
""", "talkonly")
    for f in 1 .. 400:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      t.snes.joy1 = ctx.joy1
      policy.stepOneFrame(t.snes, t.c, img)
    echo fmt"retalk win1={readU8(t.snes,0x8654):#04x} pos=(0x{readU16(t.snes,WorldXBase+PlayerSlot*SlotIndexStride):04X},0x{readU16(t.snes,WorldYBase+PlayerSlot*SlotIndexStride):04X})"
    # drain dialogue fully then pad
    loadChunk(L, AgentHomePolicy, "home")
    var maxK = pokeyKnockPercent(t.snes)
    for f in 1 .. 10000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      t.snes.joy1 = ctx.joy1
      policy.stepOneFrame(t.snes, t.c, img)
      let k = pokeyKnockPercent(t.snes)
      if k > maxK: maxK = k
      if maxK >= 80: break
    echo "after retalk AgentHome maxK=", maxK

  # pokey_done pad after dialogue drain via AgentHome first 300 frames then pure pad
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/pokey_done.state")), snes, c)
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
    for f in 1 .. 350:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
    echo fmt"FIX after 350 AgentHome pos=(0x{readU16(snes,WorldXBase+PlayerSlot*SlotIndexStride):04X},0x{readU16(snes,WorldYBase+PlayerSlot*SlotIndexStride):04X}) win1={readU8(snes,0x8654):#04x}"
    echo fmt"  then pure L d={padD(snes, c, 0x0200, 40)}"

  echo "OK probe_unlock_9600"
main()
