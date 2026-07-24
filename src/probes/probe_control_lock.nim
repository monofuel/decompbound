## Compare control-related WRAM between post_knock (frozen) and free indoor.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc r8(s: SnesBus, o: int): int = touch_grass.readU8(s, o)
proc r16(s: SnesBus, o: int): int = touch_grass.readU16(s, o)

proc dump(label: string, snes: SnesBus) =
  let i = PlayerSlot * SlotIndexStride
  echo label, " pos=(", r16(snes, WorldXBase+i).toHex(4), ",", r16(snes, WorldYBase+i).toHex(4),
    ") tg=", touchGrassPercent(snes), " knock=", pokeyKnockPercent(snes),
    " 99F2=", r8(snes, 0x99F2).toHex(2),
    " 8650=", r8(snes, 0x8650).toHex(2), " 8654=", r8(snes, 0x8654).toHex(2),
    " 0024=", r8(snes, 0x0024).toHex(2),
    " 4DBA=", r8(snes, 0x4DBA).toHex(2),
    " 5D98=", r8(snes, 0x5D98).toHex(2),
    " 9871=", r8(snes, 0x9871).toHex(2)

proc main() =
  let rom = policy.readRomFile("bin/Earthbound (U) [!].smc")
  for path in ["bin/states/llm/post_knock.state", "bin/states/llm/home_indoor.state",
               "bin/states/llm/home_downstairs_night.state", "bin/states/llm/onett_start.state"]:
    if not fileExists(path): continue
    let snes = newSnesBus(rom)
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(path)), snes, c)
    dump(path.splitPath.tail, snes)
    # try 60 frames with Right held
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let i = PlayerSlot * SlotIndexStride
    let px0 = r16(snes, WorldXBase+i)
    for f in 0 .. 60:
      snes.joy1 = 0x0100  # Right
      policy.stepOneFrame(snes, c, img)
    let px1 = r16(snes, WorldXBase+i)
    echo "  after Right x60: dx=", px1 - px0, " pos_x=", px1.toHex(4)

when isMainModule: main()
