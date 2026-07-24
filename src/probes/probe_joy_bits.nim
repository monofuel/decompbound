import std/[os, strformat], pixie
import ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy]
import ../tools/[touch_grass, story_percents]
const Rom = "bin/Earthbound (U) [!].smc"
proc tryBits(path: string; tag: string) =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  for (name, bit) in [("R_0100", 0x0100'u16), ("L_0200", 0x0200'u16),
                      ("D_0400", 0x0400'u16), ("U_0800", 0x0800'u16),
                      ("A_0080", 0x0080'u16), ("B_8000", 0x8000'u16)]:
    # reset pos each try by reloading? use sequential
    let x0 = readU16(snes, WorldXBase+i)
    let y0 = readU16(snes, WorldYBase+i)
    for _ in 1 .. 40:
      snes.joy1 = bit
      policy.stepOneFrame(snes, c, img)
    let x1 = readU16(snes, WorldXBase+i)
    let y1 = readU16(snes, WorldYBase+i)
    echo fmt"{tag} {name}: d={abs(x1-x0)+abs(y1-y0)} (0x{x0:04X},0x{y0:04X})->(0x{x1:04X},0x{y1:04X})"
proc main() =
  tryBits("bin/states/llm/pokey_done.state", "FIX")
  tryBits("bin/states/llm/onett_start.state", "DOOR")
main()
