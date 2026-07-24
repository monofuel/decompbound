## Find pad sequence from home_indoor (0x1E70,0x0150) to stairs/bedroom.
import std/[strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, policy]
import ../tools/[touch_grass, story_percents]
const Rom = "bin/Earthbound (U) [!].smc"
proc main() =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  # Try sequences
  proc runSeq(label: string; seq: openArray[tuple[bit: uint16, n: int]]) =
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
    for (bit, n) in seq:
      for _ in 1 .. n:
        snes.joy1 = bit
        policy.stepOneFrame(snes, c, img)
    echo fmt"{label} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)} room={currentRoomLabel(snes)}"

  # Down-first then left
  runSeq("Down80+Left300", [(0x0400'u16, 80), (0x0200'u16, 300)])
  runSeq("Down80+Left300+Up400", [(0x0400'u16, 80), (0x0200'u16, 300), (0x0800'u16, 400)])
  runSeq("Up40+Left300", [(0x0800'u16, 40), (0x0200'u16, 300)])
  runSeq("Up40+Left300+Up400", [(0x0800'u16, 40), (0x0200'u16, 300), (0x0800'u16, 400)])
  # zigzag
  runSeq("L50+D30+L100+U50+L100+U300", [
    (0x0200'u16, 50), (0x0400'u16, 30), (0x0200'u16, 100),
    (0x0800'u16, 50), (0x0200'u16, 100), (0x0800'u16, 300)])
  # SW diagonal style alternating
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
  for n in 1 .. 600:
    snes.joy1 = if (n mod 4) < 2: 0x0200'u16 else: 0x0400'u16
    policy.stepOneFrame(snes, c, img)
  echo fmt"alt LD pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for n in 1 .. 400:
    snes.joy1 = 0x0800
    policy.stepOneFrame(snes, c, img)
  echo fmt"then Up knock={pokeyKnockPercent(snes)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) room={currentRoomLabel(snes)}"

  # alt LU
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
  for n in 1 .. 600:
    snes.joy1 = if (n mod 4) < 2: 0x0200'u16 else: 0x0800'u16
    policy.stepOneFrame(snes, c, img)
  echo fmt"alt LU pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)}"
  for n in 1 .. 400:
    snes.joy1 = 0x0800
    policy.stepOneFrame(snes, c, img)
  echo fmt"then Up knock={pokeyKnockPercent(snes)} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) room={currentRoomLabel(snes)}"
main()
