## S3 start dump: frank_downtown WRAM, percents, scene. No WRAM writes.
import
  std/[os, strformat],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fixture = "bin/states/llm/frank_downtown.state"

proc main() =
  doAssert fileExists(Rom)
  doAssert fileExists(Fixture)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), snes, cpu)
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  echo fmt"FIXTURE={Fixture}"
  echo fmt"pos=(0x{px:04X},0x{py:04X}) indoor={px >= OutdoorMaxX} room={currentRoomLabel(snes)}"
  echo fmt"tg={touchGrassPercent(snes)} knock={pokeyKnockPercent(snes)} kc={knockComplete(snes)}"
  echo fmt"bb={buzzBuzzPercent(snes)} su={sunrisePercent(snes)}"
  echo fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} cs={captainStrongPercent(snes)}"
  echo fmt"$9887={readU8(snes, 0x9887):02X} dayOpen={dayStoryOpen(snes)} $99F2={readU8(snes, 0x99F2):02X}"
  echo fmt"$9885={readU8(snes, 0x9885):02X} $4DBA={readU8(snes, 0x4DBA):02X}"
  echo fmt"$8650={readU8(snes, 0x8650):02X} $8654={readU8(snes, 0x8654):02X}"
  echo "SPINE ", checkpointSpineLine(snes)
  echo "SCENE ", scene.sceneJson(snes)

when isMainModule:
  main()
