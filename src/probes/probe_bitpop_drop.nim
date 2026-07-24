## Which event-flag bits clear in the first N free-walk frames from soft98.

import
  std/[os, strformat, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Soft = "bin/states/llm/poo_soft98_walkable.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc snap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in 0x9A00 .. 0x9BFF:
    result[off] = readU8(snes, off)

proc main() =
  ## Walk with AgentLateGame; report first bit clears that drop popcount.
  doAssert fileExists(Rom) and fileExists(Soft)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Soft)), snes, c)
  let before = snap(snes)
  let startBp = eventFlagBitPop(snes)
  echo fmt"START bp={startBp} ma={magicantPercent(snes)} soft={hasAllSanctuarySoft(snes)}"
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
  loadChunk(L, AgentLateGamePolicy, "late")
  var reported = 0
  for f in 1 .. 500:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let bp = eventFlagBitPop(snes)
    if bp < startBp and reported < 1:
      echo fmt"FIRST_DROP f={f} bp={startBp}->{bp} ma={magicantPercent(snes)} soft={hasAllSanctuarySoft(snes)}"
      let after = snap(snes)
      var n = 0
      for off, va in before:
        let vb = after.getOrDefault(off, va)
        if va != vb:
          let lost = va and (not vb)
          let gained = vb and (not va)
          if n < 30:
            echo fmt"  ${off:04X}: 0x{va:02X}->0x{vb:02X} lost=0x{lost:02X} gain=0x{gained:02X}"
          n.inc
      echo "total_byte_diffs=", n
      reported = 1
  echo fmt"END bp={eventFlagBitPop(snes)} ma={magicantPercent(snes)}"
  echo "OK probe_bitpop_drop"

when isMainModule:
  main()
