import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ./[touch_grass, story_percents]

proc main() =
  let path = "bin/states/llm/captain_west.state"
  doAssert fileExists(path)
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let i = PlayerSlot * SlotIndexStride
  echo fmt"captain_west pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) cs={captainStrongPercent(snes)} fr={frankPercent(snes)} paula={paulaRescuePercent(snes)}"
  echo checkpointSpineLine(snes)

when isMainModule: main()
