## Referee lock for COLDATA ($2132) channel selection (fullsnes: bit5=R,
## bit6=G, bit7=B; bits 0-4 intensity). Human-verified 2026-07-09: the
## reversed mapping (bit7→R) rendered the normal grey battle swirl red.
## ROM-free: pokes the PPU port through the bus write path.

import
  ../src/decompbound/snesbus

proc main() =
  ## Assert each select bit writes exactly its hardware channel.
  ## Goes through bus.writeHook — the same path CPU/DMA/HDMA writes take.
  let rom = newSeq[uint8](0x8000)
  let snes = newSnesBus(rom)
  proc coldata(v: uint8) =
    discard snes.bus.writeHook(0x002132'u32, v)

  coldata(0x25)  # bit5 → R = 5
  doAssert snes.fixedColorR == 5 and snes.fixedColorG == 0 and snes.fixedColorB == 0,
    "bit5 must write R only"

  coldata(0x4A)  # bit6 → G = 10
  doAssert snes.fixedColorG == 10 and snes.fixedColorR == 5,
    "bit6 must write G only (R untouched)"

  coldata(0x9F)  # bit7 → B = 31
  doAssert snes.fixedColorB == 31 and snes.fixedColorR == 5 and snes.fixedColorG == 10,
    "bit7 must write B only (R/G untouched)"

  coldata(0xE3)  # all three → 3
  doAssert snes.fixedColorR == 3 and snes.fixedColorG == 3 and snes.fixedColorB == 3,
    "combined select must write all channels"

  echo "[test_coldata] ok: $2132 bit5/6/7 -> R/G/B channel select"

when isMainModule:
  main()
