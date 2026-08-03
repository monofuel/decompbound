## d85: south-commercial freeze clear ($10E5/$10E7 C0→00) restores walk to gs70.

import
  std/[os],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../src/tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  FreezePath = "bin/states/llm/south_freeze_fr90.state"

proc main() =
  doAssert fileExists(Rom)
  doAssert fileExists(FreezePath), "need south_freeze_fr90 from probe (gitignored)"
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
  doAssert readU8(snes, SouthFreezeLockA) == SouthFreezeLockVal
  doAssert readU8(snes, SouthFreezeLockB) == SouthFreezeLockVal
  doAssert frankPercent(snes) >= 90
  doAssert giantStepPercent(snes) >= 60 and giantStepPercent(snes) < 70

  # Frozen before clear
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let px0 = readU16(snes, WorldXBase + i)
  for f in 1 .. 120:
    snes.joy1 = 0x0200'u16
    policy.stepOneFrame(snes, c, img)
  doAssert readU16(snes, WorldXBase + i) == px0, "must be frozen before clear"

  clearSouthFreezeLocks(snes)
  doAssert readU8(snes, SouthFreezeLockA) == SouthFreezeClearVal
  doAssert readU8(snes, SouthFreezeLockB) == SouthFreezeClearVal
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8

  var maxGs = giantStepPercent(snes)
  var maxStep = 0
  var lastX = readU16(snes, WorldXBase + i)
  var lastY = readU16(snes, WorldYBase + i)
  for f in 1 .. 600:
    snes.joy1 = 0x0200'u16
    if (f mod 36) < 10: snes.joy1 = 0x0A00'u16
    policy.stepOneFrame(snes, c, img)
    clearSouthFreezeLocks(snes)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let step = abs(int(px) - int(lastX)) + abs(int(py) - int(lastY))
    if step > maxStep: maxStep = step
    lastX = px
    lastY = py
    let gs = giantStepPercent(snes)
    if gs > maxGs: maxGs = gs
  echo "after clear maxGs=", maxGs, " maxStep=", maxStep, " end_x=", lastX, " end_y=", lastY
  doAssert maxStep > 0 and maxStep <= 8, "walk-like steps after clear"
  doAssert maxGs >= 70, "gs70 after freeze clear"
  echo "OK test_south_freeze_clear"

when isMainModule:
  main()
