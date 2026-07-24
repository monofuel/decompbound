## Hunt Magicant/Giygas flag candidates across all llm + slot states + free walk.
## Looks for bits unique to high-bitpop late states vs midgame, and for solo-Ness
## dream-like party shapes.

import
  std/[os, strformat, strutils, tables, algorithm, sequtils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const Rom = "bin/Earthbound (U) [!].smc"

proc loadPath(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile(Rom))
  var c = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, c)

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc grade(path: string) =
  if not fileExists(path): return
  let snes = loadPath(path)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{extractFilename(path)}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X},{readU8(snes,0x988E):02X} " &
    fmt"lv={partyLeaderLevel(snes)} size={partySize(snes)} bp={eventFlagBitPop(snes)} " &
    fmt"ma={magicantPercent(snes)} gi={giygasPercent(snes)} " &
    fmt"dream={hasMagicantDreamFlag(snes)} giFlag={hasGiygasPhaseFlag(snes)} soft={hasAllSanctuarySoft(snes)}"

proc bitsSet(snes: SnesBus): seq[(int, int)] =
  ## List (offset, bit) for set bits in $9A00..$9BFF.
  for off in 0x9A00 .. 0x9BFF:
    let v = readU8(snes, off)
    for bit in 0 .. 7:
      if (v and (1 shl bit)) != 0:
        result.add (off, bit)

proc main() =
  echo "=== GRADES ==="
  for p in [
    "bin/states/llm/captain_west.state",
    "bin/states/llm/midgame_approach.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/poo_deep_south.state",
    "bin/states/llm/poo_very_deep.state",
    "bin/states/llm/poo_free_outdoor.state",
    "bin/states/llm/poo_bitpop_walk.state",
    "bin/states/llm/ness_solo_late.state",
    "bin/states/llm/poo_solo.state",
    "bin/states/battle_menu_healthy.state",
    "bin/states/slot1.state"
  ]:
    grade(p)

  # Bits set only in very_deep among {mid, poo, deep, very} — late-only candidates
  if fileExists("bin/states/llm/midgame_approach.state") and
      fileExists("bin/states/llm/poo_very_deep.state") and
      fileExists("bin/states/llm/poo_joined.state"):
    let mid = loadPath("bin/states/llm/midgame_approach.state")
    let poo = loadPath("bin/states/llm/poo_joined.state")
    let deep = loadPath("bin/states/llm/poo_deep_south.state")
    let very = loadPath("bin/states/llm/poo_very_deep.state")
    echo "=== bits in very only (not mid/poo/deep) ==="
    var onlyVery = 0
    for off in 0x9A00 .. 0x9BFF:
      for bit in 0 .. 7:
        let mask = 1 shl bit
        let vv = readU8(very, off) and mask
        if vv == 0: continue
        let vm = readU8(mid, off) and mask
        let vp = readU8(poo, off) and mask
        let vd = readU8(deep, off) and mask
        if vm == 0 and vp == 0 and vd == 0:
          if onlyVery < 25:
            echo fmt"  ${off:04X}.b{bit}"
          onlyVery.inc
    echo "very_only_bits=", onlyVery

    echo "=== bits in very+deep not mid (late Poo map) ==="
    var lateMap = 0
    for off in 0x9A00 .. 0x9BFF:
      for bit in 0 .. 7:
        let mask = 1 shl bit
        if (readU8(mid, off) and mask) != 0: continue
        if (readU8(very, off) and mask) == 0: continue
        if (readU8(deep, off) and mask) == 0: continue
        if lateMap < 20:
          echo fmt"  ${off:04X}.b{bit}"
        lateMap.inc
    echo "late_map_bits=", lateMap

  # Long free walk from poo_very_deep: capture peak bitpop + any NEW stable bits
  if fileExists("bin/states/llm/poo_very_deep.state"):
    let snes = loadPath("bin/states/llm/poo_very_deep.state")
    var c = snes.resetCpu()
    # reload properly
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/poo_very_deep.state")), snes, c)
    let before = bitsSet(snes)
    var beforeSet = initTable[string, bool]()
    for b in before:
      beforeSet[fmt"{b[0]:04X}.{b[1]}"] = true
    let startBp = eventFlagBitPop(snes)
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(
      snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox()
    policy.setupPolicyApi(L, ctx)
    loadChunk(L, EscapeMenuSkillLua & "\n" & WinBattleSkillLua, "sk")
    loadChunk(L, AgentLateGamePolicy, "late")
    var maxBp = startBp
    var maxMa = magicantPercent(snes)
    let i = PlayerSlot * SlotIndexStride
    var stuck = 0
    var recoveries = 0
    var prevX = readU16(snes, WorldXBase + i)
    var prevY = readU16(snes, WorldYBase + i)
    writeFile("bin/states/llm/rollback.state", cast[string](serializeState(snes, c)))
    echo "STUCK_ANCHOR for late free walk"
    for f in 1 .. 10000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      let bp = eventFlagBitPop(snes)
      let ma = magicantPercent(snes)
      if bp > maxBp:
        maxBp = bp
        echo fmt"NEW bitpop={bp} f={f} ma={ma} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
      if ma > maxMa: maxMa = ma
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      if abs(px - prevX) + abs(py - prevY) <= 2:
        stuck.inc
      else:
        stuck = 0
      prevX = px
      prevY = py
      if stuck > 100:
        recoveries.inc
        echo fmt"STUCK_DETECTED; STUCK_RECOVERY replan#{recoveries}"
        deserializeState(cast[seq[byte]](readFile("bin/states/llm/rollback.state")), snes, c)
        loadChunk(L, AgentLateGamePolicy, "replan")
        stuck = 0
      if f mod 2500 == 0:
        echo fmt"f={f} bp={bp} ma={ma} gi={giygasPercent(snes)} lv={partyLeaderLevel(snes)}"
    let after = bitsSet(snes)
    var newBits = 0
    for b in after:
      let k = fmt"{b[0]:04X}.{b[1]}"
      if not beforeSet.hasKey(k):
        if newBits < 15:
          echo fmt"  NEWBIT ${b[0]:04X}.b{b[1]}"
        newBits.inc
    echo fmt"FINAL walk maxBp={maxBp} maxMa={maxMa} newBits={newBits} recoveries={recoveries}"
    echo "  ", checkpointSpineLine(snes)
    writeFile("bin/states/llm/poo_magicant_approach.state", cast[string](serializeState(snes, c)))
    echo "WROTE poo_magicant_approach"
  echo "OK probe_magicant_candidates"

when isMainModule:
  main()
