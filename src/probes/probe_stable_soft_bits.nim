## Bits set in very_deep after excluding post-walk-cleared 0xFF, vs midgame.
import std/[os, strformat, tables], pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]
const Rom = "bin/Earthbound (U) [!].smc"
proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK: raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK: raise newException(ValueError, $L.toString(-1))
proc loadP(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile(Rom))
  var c = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, c)
proc bits(snes: SnesBus): Table[string, bool] =
  result = initTable[string, bool]()
  for off in 0x9A00 .. 0x9BFF:
    let v = readU8(snes, off)
    for b in 0..7:
      if (v and (1 shl b)) != 0:
        result[fmt"{off:04X}.{b}"] = true
let mid = loadP("bin/states/llm/midgame_approach.state")
let very = loadP("bin/states/llm/poo_very_deep.state")
# walk very 5 frames
let walked = loadP("bin/states/llm/poo_very_deep.state")
var c = walked.resetCpu()
deserializeState(cast[seq[byte]](readFile("bin/states/llm/poo_very_deep.state")), walked, c)
let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
let ctx = policy.PolicyContext(snes: walked, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
loadChunk(L, AgentLateGamePolicy, "late")
for f in 1..30:
  ctx.frameCount = f
  discard policy.runPolicyFrame(L, ctx)
  walked.joy1 = ctx.joy1
  policy.stepOneFrame(walked, c, img)
let bm = bits(mid)
let bv = bits(very)
let bw = bits(walked)
echo "very_only_vs_mid (still set after walk):"
var n = 0
for k, _ in bv:
  if bm.hasKey(k): continue
  if not bw.hasKey(k): continue  # must survive walk
  if n < 40: echo "  ", k
  n.inc
echo "stable_very_only=", n
echo "cleared_on_walk that were very-only:"
var n2 = 0
for k, _ in bv:
  if bm.hasKey(k): continue
  if bw.hasKey(k): continue
  if n2 < 20: echo "  CLEAR ", k
  n2.inc
echo "cleared_very_only=", n2
echo "walked bp=", eventFlagBitPop(walked), " ma=", magicantPercent(walked)
