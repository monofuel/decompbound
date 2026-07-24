## d85e: validate single-byte unlocks for south freeze; check warp vs walk.

import
  std/[os, strformat, sequtils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  FreezePath = "bin/states/llm/south_freeze_fr90.state"

proc main() =
  let fre = newSnesBus(policy.readRomFile(Rom))
  var cf = fre.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), fre, cf)
  let frz = newSnesBus(policy.readRomFile(Rom))
  var cz = frz.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), frz, cz)

  let candidates = [0x10E7, 0x1FE9, 0x1FEA, 0x1FEB, 0x1FED, 0x1FEE, 0x1FF0]
  for off in candidates:
    echo fmt"=== trial ${off:04X} freeze={readU8(frz,off):02X} free={readU8(fre,off):02X} ==="
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    let px0 = readU16(snes, WorldXBase + i)
    let py0 = readU16(snes, WorldYBase + i)
    snes.bus.mem[0x7E0000 + off] = uint8(readU8(fre, off))
    snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
    snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    var maxStep = 0
    var lastPx = px0
    var lastPy = py0
    for f in 1 .. 300:
      snes.joy1 = 0x0100'u16 # Right
      policy.stepOneFrame(snes, c, img)
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      let step = abs(int(px) - int(lastPx)) + abs(int(py) - int(lastPy))
      if step > maxStep: maxStep = step
      if f <= 5 or f mod 50 == 0:
        echo fmt"  f={f} pos=(0x{px:04X},0x{py:04X}) step={step}"
      lastPx = px
      lastPy = py
    let px1 = readU16(snes, WorldXBase + i)
    let py1 = readU16(snes, WorldYBase + i)
    echo fmt"  END start=(0x{px0:04X},0x{py0:04X}) end=(0x{px1:04X},0x{py1:04X}) " &
      fmt"net={abs(int(px1)-int(px0))+abs(int(py1)-int(py0))} maxStep={maxStep} " &
      fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} cs={captainStrongPercent(snes)}"

  # Minimal combo: $10E7 alone vs $10E7 + $1FE9
  for label, offs in [
    ("10E7", @[0x10E7]),
    ("1FE9", @[0x1FE9]),
    ("10E7+1FE9", @[0x10E7, 0x1FE9]),
    ("10E0-10EF", toSeq(0x10E0..0x10EF)),
  ].items:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    for off in offs:
      snes.bus.mem[0x7E0000 + off] = uint8(readU8(fre, off))
    snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let px0 = readU16(snes, WorldXBase + i)
    var maxStep = 0
    var last = px0
    for f in 1 .. 250:
      snes.joy1 = 0x0200'u16 # Left toward gs70
      policy.stepOneFrame(snes, c, img)
      let px = readU16(snes, WorldXBase + i)
      let step = abs(int(px) - int(last))
      if step > maxStep: maxStep = step
      last = px
    let px1 = readU16(snes, WorldXBase + i)
    let py1 = readU16(snes, WorldYBase + i)
    echo fmt"LEFT {label} end=(0x{px1:04X},0x{py1:04X}) dx={int(px1)-int(px0)} maxStep={maxStep} gs={giantStepPercent(snes)}"

  echo "OK probe_south_freeze_bytes"

when isMainModule:
  main()
