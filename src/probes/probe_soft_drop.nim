## How many frames until soft ma98 drops after load of poo_soft98_walkable.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Soft = "bin/states/llm/poo_soft98_walkable.state"

proc main() =
  ## Idle frames (no input) then Down-hold — report soft/bitpop drop timing.
  doAssert fileExists(Rom) and fileExists(Soft)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Soft)), snes, c)
  echo fmt"f=0 ma={magicantPercent(snes)} gi={giygasPercent(snes)} bp={eventFlagBitPop(snes)} " &
    fmt"soft={hasAllSanctuarySoft(snes)} $5E06={readU8(snes,0x5E06):02X}"
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for f in 1 .. 60:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    if f in [1, 2, 3, 5, 10, 15, 30, 60]:
      echo fmt"idle f={f} ma={magicantPercent(snes)} bp={eventFlagBitPop(snes)} " &
        fmt"soft={hasAllSanctuarySoft(snes)} lv={partyLeaderLevel(snes)}"
  echo "OK probe_soft_drop"

when isMainModule:
  main()
