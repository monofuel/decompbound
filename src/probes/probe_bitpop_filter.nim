import std/[os, strformat], pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
const Soft = "bin/states/llm/poo_soft98_walkable.state"
proc popNoFF(snes: SnesBus): int =
  for off in 0x9A00 .. 0x9BFF:
    let v = readU8(snes, off)
    if v == 0xFF: continue
    var x = v
    while x > 0:
      if (x and 1) != 0: result.inc
      x = x shr 1
proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK: raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK: raise newException(ValueError, $L.toString(-1))
let snes = newSnesBus(policy.readRomFile(Rom))
var c = snes.resetCpu()
deserializeState(cast[seq[byte]](readFile(Soft)), snes, c)
echo "START raw=", eventFlagBitPop(snes), " noFF=", popNoFF(snes)
let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
let L = lua53.newstate()
L.openSandbox(); policy.setupPolicyApi(L, ctx)
loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
loadChunk(L, AgentLateGamePolicy, "late")
for f in 1..200:
  ctx.frameCount = f
  discard policy.runPolicyFrame(L, ctx)
  snes.joy1 = ctx.joy1
  policy.stepOneFrame(snes, c, img)
  if f in [1, 10, 50, 100, 200]:
    echo "f=", f, " raw=", eventFlagBitPop(snes), " noFF=", popNoFF(snes), " mid=", eventFlagBitPop(snes) # placeholder
# also grade midgame noFF
for p in ["bin/states/llm/midgame_approach.state", "bin/states/llm/poo_joined.state", "bin/states/llm/poo_very_deep.state", "bin/states/llm/captain_west.state"]:
  let s2 = newSnesBus(policy.readRomFile(Rom))
  var c2 = s2.resetCpu()
  deserializeState(cast[seq[byte]](readFile(p)), s2, c2)
  echo extractFilename(p), " raw=", eventFlagBitPop(s2), " noFF=", popNoFF(s2)
