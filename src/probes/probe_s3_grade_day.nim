## Read-only grade of day/arcade fixtures for S3 door RE. No WRAM writes.
import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Paths = [
    "bin/states/llm/frank_downtown.state",
    "bin/states/llm/frank_arcade.state",
    "bin/states/llm/giant_approach.state",
    "bin/states/llm/leave_day1_map.state",
    "bin/states/llm/leave_day1_noparty.state",
    "bin/states/llm/south_freeze_fr90.state",
  ]
  SpriteGroupBase = 0x2CD6
  SpritePtrBase = 0x29CA

proc grade(path: string) =
  if not fileExists(path):
    echo "MISS ", path
    return
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  echo fmt"{extractFilename(path)}: pos=(0x{px:04X},0x{py:04X}) indoor={px >= OutdoorMaxX} " &
    fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} cs={captainStrongPercent(snes)} " &
    fmt"$9887={readU8(snes, 0x9887):02X} day={dayStoryOpen(snes)} $99F2={readU8(snes, 0x99F2):02X} " &
    fmt"room={currentRoomLabel(snes)}"
  for s in 0 .. 27:
    if s == PlayerSlot: continue
    let si = s * SlotIndexStride
    let x = readU16(snes, WorldXBase + si)
    let y = readU16(snes, WorldYBase + si)
    if (x == 0 and y == 0) or x == 0xFFFF: continue
    let d = (abs(x - px) + abs(y - py)) div 8
    if d > 40: continue
    let g = readU16(snes, SpriteGroupBase + si)
    let p = readU16(snes, SpritePtrBase + si)
    echo fmt"  near s={s} g=0x{g:04X} p=0x{p:04X} pos=(0x{x:04X},0x{y:04X}) d={d}"

proc main() =
  for p in Paths:
    grade(p)

when isMainModule:
  main()
