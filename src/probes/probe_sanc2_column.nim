## Dump pos + BG scroll from 2nd-sanctuary F12s (black viewport column).

import
  std/[os, options, strformat],
  ../decompbound/[png_state, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  Shots = [
    "/home/monofuel/Pictures/Screenshots/earthbound_20260818-005541.png",
    "/home/monofuel/Pictures/Screenshots/earthbound_20260818-005543.png",
    "/home/monofuel/Pictures/Screenshots/earthbound_20260818-005556.png",
    "/home/monofuel/Pictures/Screenshots/earthbound_20260707-014807.png",
    "/home/monofuel/Pictures/Screenshots/earthbound_20260707-014825.png",
    "/home/monofuel/Pictures/Screenshots/earthbound_20260707-014835.png",
  ]

proc readRom(path: string): seq[uint8] =
  ## ROM bytes minus copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc main() =
  ## Print player pos and BG1/2 scroll for each sanctuary F12.
  let rom = readRom(RomPath)
  for p in Shots:
    let st = extractState(cast[seq[uint8]](readFile(p)))
    if st.isNone:
      echo p.extractFilename, " NO ebSt"
      continue
    let snes = newSnesBus(rom)
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](st.get), snes, c)
    let pos = playerPos(snes)
    echo &"{p.extractFilename}  pos=({pos.x:04X},{pos.y:04X}) " &
      &"bg1=({snes.bgScroll[0]},{snes.bgScroll[1]}) " &
      &"bg2=({snes.bgScroll[2]},{snes.bgScroll[3]}) " &
      &"BGMODE={snes.ppuRegs[0x05]:02X} TM={snes.ppuRegs[0x2C]:02X} " &
      &"HDMAEN={snes.hdmaen:02X} BG1SC={snes.ppuRegs[0x07]:02X}"

when isMainModule:
  main()
