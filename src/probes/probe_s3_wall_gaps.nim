## Find northbound holes in downtown solid walls (real door gaps).
import
  std/[strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/touch_grass

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fixture = "bin/states/llm/frank_downtown.state"
  CollisionPage = 0xE000

proc col(snes: SnesBus; px, py: int): int =
  let cx = (px shr 3) and 0x3F
  let cy = (py shr 3) and 0x3F
  readU8(snes, CollisionPage + ((cy shl 6) or cx))

proc openTile(b: int): bool =
  (b and 0xD0) == 0

proc main() =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), snes, cpu)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"player=(0x{readU16(snes, WorldXBase+i):04X},0x{readU16(snes, WorldYBase+i):04X})"
  echo fmt"house door (0x0A60,0x0158) here=0x{col(snes, 0x0A60, 0x0158):02X} " &
    fmt"north=0x{col(snes, 0x0A60, 0x0150):02X} south=0x{col(snes, 0x0A60, 0x0160):02X}"
  echo "NORTH_GAPS: open tile, open north, solid neighbor (door-sized hole)"
  for ty in countup(0x0140, 0x02B0, 8):
    for tx in countup(0x0860, 0x0AC0, 8):
      let here = col(snes, tx, ty)
      let north = col(snes, tx, ty - 8)
      let west = col(snes, tx - 8, ty)
      let east = col(snes, tx + 8, ty)
      if openTile(here) and openTile(north) and (not openTile(west) or not openTile(east)):
        echo fmt"  gap (0x{tx:04X},0x{ty:04X}) here=0x{here:02X} N=0x{north:02X} " &
          fmt"W=0x{west:02X} E=0x{east:02X}"

when isMainModule:
  main()
