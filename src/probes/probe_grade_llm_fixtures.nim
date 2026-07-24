import std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ./story_percents

const Rom = "bin/Earthbound (U) [!].smc"
proc main() =
  for p in [
    "midgame_approach", "midgame_deep", "midgame_wander",
    "leave_day1_map", "leave_onett_walkable", "campaign_captain_best",
    "fourside60_freewalk", "poo_joined", "poo_deep_south",
    "campaign_late_best", "giant_approach", "post_knock_outdoor"
  ]:
    let path = "bin/states/llm/" & p & ".state"
    if not fileExists(path):
      echo "miss ", p
      continue
    var snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    echo fmt"{p}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) {checkpointSpineLine(snes)}"
main()
