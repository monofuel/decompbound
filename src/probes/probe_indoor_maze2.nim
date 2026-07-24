import std/[strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, policy]
import ../tools/[touch_grass, story_percents]
const Rom = "bin/Earthbound (U) [!].smc"
proc main() =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/home_indoor.state")), snes, c)
  # Sustained: prefer Left, peel Up/Down when stuck
  var stuck = 0
  var last = 0
  for n in 1 .. 2000:
    let px = readU16(snes, WorldXBase+i)
    let py = readU16(snes, WorldYBase+i)
    let p = px.int + py.int * 100000
    if p == last: stuck.inc else: stuck = 0
    last = p
    if px <= 0x1CC8:
      snes.joy1 = 0x0800
    elif stuck > 20:
      snes.joy1 = if (stuck div 20) mod 2 == 0: 0x0400'u16 else: 0x0800'u16
    else:
      snes.joy1 = 0x0200
    policy.stepOneFrame(snes, c, img)
    if n mod 100 == 0 or pokeyKnockPercent(snes) >= 80:
      echo fmt"n={n} pos=(0x{px:04X},0x{py:04X}) stuck={stuck} knock={pokeyKnockPercent(snes)} room={currentRoomLabel(snes)}"
    if pokeyKnockPercent(snes) >= 80: break
  # more up
  for n in 1 .. 500:
    snes.joy1 = 0x0800
    policy.stepOneFrame(snes, c, img)
    if n mod 50 == 0:
      echo fmt"up n={n} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) knock={pokeyKnockPercent(snes)} room={currentRoomLabel(snes)}"
    if pokeyKnockPercent(snes) >= 80: break
  echo "FINAL knock=", pokeyKnockPercent(snes), " room=", currentRoomLabel(snes)
main()
