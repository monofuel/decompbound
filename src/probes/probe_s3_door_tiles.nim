## Scan live collision for pass tiles abutting solid walls (door candidates).
import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fixture = "bin/states/llm/frank_downtown.state"
  CollisionPage = 0xE000

proc col(snes: SnesBus; px, py: int): int =
  let cx = (px shr 3) and 0x3F
  let cy = (py shr 3) and 0x3F
  readU8(snes, CollisionPage + ((cy shl 6) or cx))

proc main() =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), snes, cpu)
  echo "DOOR_CANDIDATES pass-tile south of solid (building face)"
  for ty in countup(0x0200, 0x02B0, 8):
    for tx in countup(0x0860, 0x0AA0, 8):
      let here = col(snes, tx, ty)
      let north = col(snes, tx, ty - 8)
      if here != 0x80 and north == 0x80 and (here == 0x00 or here == 0x01 or here == 0x03):
        echo fmt"  face (0x{tx:04X},0x{ty:04X}) here=0x{here:02X} north=0x{north:02X}"

when isMainModule:
  main()
