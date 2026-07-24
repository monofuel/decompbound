## Free-walk late outdoor; track event-flag bitpop and spine.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

proc bitPop(snes: SnesBus): int =
  for off in 0x9A00 .. 0x9BFF:
    var v = readU8(snes, off)
    while v > 0:
      if (v and 1) != 0: result.inc
      v = v shr 1

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  let path = "bin/states/llm/poo_very_deep.state"
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let startBp = bitPop(snes)
  echo "START bp=", startBp, " ", checkpointSpineLine(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  var maxBp = startBp
  var maxMa = magicantPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 12000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let bp = bitPop(snes)
    let ma = magicantPercent(snes)
    if bp > maxBp:
      maxBp = bp
      echo fmt"NEW bitpop={bp} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) ma={ma}"
    if ma > maxMa: maxMa = ma
    if f mod 3000 == 0:
      echo fmt"f={f} bp={bp} ma={ma} lv={partyLeaderLevel(snes)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  echo "FINAL maxBp=", maxBp, " maxMa=", maxMa, " ", checkpointSpineLine(snes)
  writeFile("bin/states/llm/poo_bitpop_walk.state", cast[string](serializeState(snes, c)))
  echo "WROTE poo_bitpop_walk bp=", bitPop(snes)

when isMainModule: main()
