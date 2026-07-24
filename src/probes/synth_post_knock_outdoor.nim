## Synthesize a *playable* post-knock outdoor fixture.
##
## Real `post_knock.state` freezes player input. Free outdoor (`onett_start`) is
## mobile. Verified 2026-07-24:
##   - `$99F2=$58` alone → knockComplete + mobile + crater route → buzz 80 at site
##   - Full `$9880..$9FFF` copy from post_knock → mobile but mid-route warp/dialogue thrash
##   - Minimal overlay: `$99F2` + `$9887=01` (knock story bit from post_knock flagdiff)
##
## Usage: nim r -d:release src/probes/synth_post_knock_outdoor.nim

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutPath = "bin/states/llm/post_knock_outdoor.state"
  OutdoorBase = "bin/states/llm/onett_start.state"

proc main() =
  ## Build free outdoor post-knock with minimal verified knock signatures.
  doAssert fileExists(Rom)
  doAssert fileExists(OutdoorBase), "need onett_start outdoor base"
  createDir("bin/states/llm")

  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorBase)), snes, cpu)

  # Minimal knock signatures (full flag-band overlay causes mid-route warps).
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. 30:
    snes.joy1 = 0
    policy.stepOneFrame(snes, cpu, img)

  doAssert knockComplete(snes)
  doAssert touchGrassPercent(snes) >= 100
  doAssert readU8(snes, KnockStoryFlagOff) == KnockStoryFlagVal
  doAssert buzzBuzzPercent(snes) >= 40
  doAssert frankPercent(snes) >= 20

  let i = PlayerSlot * SlotIndexStride
  let px0 = readU16(snes, WorldXBase + i)
  for _ in 0 .. 90:
    snes.joy1 = 0x0100
    policy.stepOneFrame(snes, cpu, img)
  let px1 = readU16(snes, WorldXBase + i)
  doAssert abs(px1 - px0) > 4, "synth outdoor must be mobile under d-pad"

  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  writeFile(OutPath, cast[string](serializeState(snes, cpu)))
  echo fmt"WROTE {OutPath} knock={pokeyKnockPercent(snes)} kc={knockComplete(snes)} tg={touchGrassPercent(snes)} bb={buzzBuzzPercent(snes)} fr={frankPercent(snes)} $9887=0x{readU8(snes,KnockStoryFlagOff):02X} mobility_dx={px1-px0}"

when isMainModule:
  main()
