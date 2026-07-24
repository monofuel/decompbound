## d85f: isolate $10E0-$10EF bytes that restore real walk to gs70.

import
  std/[os, strformat, sequtils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  FreezePath = "bin/states/llm/south_freeze_fr90.state"

proc runLeft(fre: SnesBus; offs: openArray[int]; frames = 400):
    tuple[endX, endY, maxStep, gs, fr: int] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  for off in offs:
    snes.bus.mem[0x7E0000 + off] = fre.bus.mem[0x7E0000 + off]
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var lastX = readU16(snes, WorldXBase + i)
  var lastY = readU16(snes, WorldYBase + i)
  result.maxStep = 0
  for f in 1 .. frames:
    snes.joy1 = 0x0200'u16
    if (f mod 40) < 8: snes.joy1 = 0x0A00'u16 # Left+Up peel
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let step = abs(int(px) - int(lastX)) + abs(int(py) - int(lastY))
    if step > result.maxStep: result.maxStep = step
    lastX = px
    lastY = py
  result.endX = readU16(snes, WorldXBase + i)
  result.endY = readU16(snes, WorldYBase + i)
  result.gs = giantStepPercent(snes)
  result.fr = frankPercent(snes)

proc main() =
  let fre = newSnesBus(policy.readRomFile(Rom))
  var cf = fre.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), fre, cf)
  let frz = newSnesBus(policy.readRomFile(Rom))
  var cz = frz.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), frz, cz)

  echo "=== $10E0-$10EF freeze vs free ==="
  for off in 0x10E0 .. 0x10EF:
    echo fmt"  ${off:04X}: freeze={readU8(frz,off):02X} free={readU8(fre,off):02X}"

  # full window
  var win: seq[int] = toSeq(0x10E0..0x10EF)
  var r = runLeft(fre, win)
  echo fmt"FULL window end=(0x{r.endX:04X},0x{r.endY:04X}) maxStep={r.maxStep} gs={r.gs} fr={r.fr}"

  # single bytes that differ
  var diffs: seq[int] = @[]
  for off in 0x10E0 .. 0x10EF:
    if readU8(frz, off) != readU8(fre, off):
      diffs.add off
      r = runLeft(fre, [off])
      let ok = r.maxStep <= 8 and r.maxStep > 0 # walk-like
      echo fmt"single ${off:04X} end=(0x{r.endX:04X},0x{r.endY:04X}) maxStep={r.maxStep} gs={r.gs} walkish={ok}"

  # all diffs
  r = runLeft(fre, diffs)
  echo fmt"all diffs end=(0x{r.endX:04X},0x{r.endY:04X}) maxStep={r.maxStep} gs={r.gs}"

  # leave-one-out
  for skip in diffs:
    var offs: seq[int] = @[]
    for o in diffs:
      if o != skip: offs.add o
    r = runLeft(fre, offs)
    echo fmt"leave-out ${skip:04X} end=(0x{r.endX:04X},0x{r.endY:04X}) maxStep={r.maxStep} gs={r.gs}"

  # progressive add diffs in order
  var acc: seq[int] = @[]
  for o in diffs:
    acc.add o
    r = runLeft(fre, acc)
    echo fmt"acc +${o:04X} end=(0x{r.endX:04X},0x{r.endY:04X}) maxStep={r.maxStep} gs={r.gs}"

  echo "OK probe_south_freeze_10e0"

when isMainModule:
  main()
