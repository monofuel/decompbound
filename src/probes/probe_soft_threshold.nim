import std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]
const Rom = "bin/Earthbound (U) [!].smc"
for p in ["bin/states/llm/midgame_approach.state", "bin/states/llm/poo_joined.state",
          "bin/states/llm/poo_deep_south.state", "bin/states/llm/poo_very_deep.state",
          "bin/states/llm/poo_free_outdoor.state", "bin/states/llm/poo_soft98_walkable.state",
          "bin/states/llm/captain_west.state", "bin/states/llm/poo_solo.state"]:
  if not fileExists(p): continue
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(p)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{extractFilename(p)} lv={partyLeaderLevel(snes)} bp={eventFlagBitPop(snes)} " &
    fmt"py=0x{readU16(snes, WorldYBase+i):04X} fo={foursidePercent(snes)} " &
    fmt"ma={magicantPercent(snes)} soft={hasAllSanctuarySoft(snes)} poo={partyHasChar(snes, PartyCharPoo)}"
