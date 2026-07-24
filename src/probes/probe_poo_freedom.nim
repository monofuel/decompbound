## Which Poo-era llm fixtures allow free walk?
import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents, llm_mock_policies]
proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK: raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK: raise newException(ValueError, $L.toString(-1))
proc spanOf(path: string): int =
  if not fileExists(path): return -1
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase+i); var maxX = minX
  var minY = readU16(snes, WorldYBase+i); var maxY = minY
  for f in 1..2000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase+i); let py = readU16(snes, WorldYBase+i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  result = (maxX-minX)+(maxY-minY)
  echo fmt"{extractFilename(path)} span={result} fo={foursidePercent(snes)} ma={magicantPercent(snes)} gi={giygasPercent(snes)} bbox=0x{minX:04X}..0x{maxX:04X},0x{minY:04X}..0x{maxY:04X}"
  if result >= 100:
    writeFile("bin/states/llm/poo_free_outdoor.state", cast[string](serializeState(snes, c)))
    echo "WROTE poo_free_outdoor"
for p in ["bin/states/llm/poo_joined.state", "bin/states/llm/poo_deep_south.state",
          "bin/states/llm/poo_very_deep.state", "bin/states/llm/poo_late_map.state",
          "bin/states/llm/poo_solo.state", "bin/states/llm/fourside_deep_prepoo.state",
          "bin/states/llm/poo_indoor_late.state"]:
  discard spanOf(p)
