## Extract high-bitpop late F12 → bin/states/llm/poo_high_bitpop.state (local only).

import
  std/[os, strformat, options],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Src = "/home/monofuel/Pictures/Screenshots/earthbound_20260723-233608.png"
  Out = "bin/states/llm/poo_high_bitpop.state"

proc main() =
  ## Pull ebSt from high-bp F12 for late Agent probes (never commit the state).
  doAssert fileExists(Rom) and fileExists(Src)
  let st = extractState(cast[seq[uint8]](readFile(Src)))
  doAssert st.isSome, "need ebSt chunk"
  writeFile(Out, cast[string](st.get))
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(st.get, snes, c)
  echo "WROTE ", Out, " ", checkpointSpineLine(snes),
    " bp=", eventFlagBitPop(snes), " lv=", readU8(snes, PartyLeaderLevelOff),
    " dream=", hasMagicantDreamFlag(snes)
  echo "OK synth_high_bitpop"

when isMainModule:
  main()
