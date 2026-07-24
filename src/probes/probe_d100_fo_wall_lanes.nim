## d100: fo wall freewalk lane scan from midgame_approach (correct joy masks).

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Mid = "bin/states/llm/midgame_approach.state"
  BtnRight = 0x0100'u16
  BtnLeft = 0x0200'u16
  BtnDown = 0x0400'u16
  BtnUp = 0x0800'u16

proc settle(snes: SnesBus; c: var Cpu; n = 15) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for _ in 0 .. n:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
    applyLaterStoryLeaveSoft(snes)

proc main() =
  doAssert fileExists(Rom) and fileExists(Mid)
  echo "PROBE=d100 fo wall freewalk lane scan"
  var snes0 = newSnesBus(policy.readRomFile(Rom))
  var c0 = snes0.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Mid)), snes0, c0)
  applyLaterStoryLeaveSoft(snes0)
  settle(snes0, c0)
  let i = PlayerSlot * SlotIndexStride
  let startX = readU16(snes0, WorldXBase + i).int
  let startY = readU16(snes0, WorldYBase + i).int
  echo fmt"START pos=(0x{startX:04X},0x{startY:04X}) fo={foursidePercent(snes0)}"

  var bestY = startY
  var bestFo = foursidePercent(snes0)
  var bestLabel = "none"
  for dx in [-0x180, -0x80, 0, 0x80, 0x180, 0x280]:
    for mix in 0 .. 2:
      var snes = newSnesBus(policy.readRomFile(Rom))
      var c = snes.resetCpu()
      deserializeState(cast[seq[byte]](readFile(Mid)), snes, c)
      applyLaterStoryLeaveSoft(snes)
      settle(snes, c)
      let nx = (startX + dx).clamp(0x0200, 0x1A00)
      snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(nx and 0xFF)
      snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8((nx shr 8) and 0xFF)
      let ny = 0x1760
      snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(ny and 0xFF)
      snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8((ny shr 8) and 0xFF)
      clearSouthFreezeLocks(snes)
      settle(snes, c, 4)
      let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
      var lastPx = nx
      var lastPy = ny
      var maxY = ny
      var maxFo = foursidePercent(snes)
      var walk = 0
      var tele = 0
      for f in 1 .. 1200:
        clearSouthFreezeLocks(snes)
        case mix
        of 0: snes.joy1 = BtnDown
        of 1: snes.joy1 = BtnDown or BtnRight
        else: snes.joy1 = BtnDown or BtnLeft
        policy.stepOneFrame(snes, c, img)
        applyLaterStoryLeaveSoft(snes)
        clearSouthFreezeLocks(snes)
        let px = readU16(snes, WorldXBase + i).int
        let py = readU16(snes, WorldYBase + i).int
        let ddx = abs(px - lastPx); let ddy = abs(py - lastPy)
        if ddx > 32 or ddy > 32: inc tele
        else: walk += ddx + ddy
        lastPx = px; lastPy = py
        if py > maxY: maxY = py
        let fo = foursidePercent(snes)
        if fo > maxFo: maxFo = fo
      let label = fmt"dx={dx:#x} mix={mix}"
      echo fmt"LANE {label} maxY=0x{maxY:04X} maxFo={maxFo} walk={walk} tele={tele} end=(0x{lastPx:04X},0x{lastPy:04X})"
      if maxY > bestY or maxFo > bestFo:
        bestY = maxY; bestFo = maxFo; bestLabel = label

  echo fmt"SUMMARY best={bestLabel} maxY=0x{bestY:04X} maxFo={bestFo}"
  if bestFo >= 60:
    echo "BREAK fo60 freewalk lane found"
  else:
    echo fmt"NOTE fo wall sealed maxFo={bestFo} maxY=0x{bestY:04X}"
  echo "OK probe_d100_fo_wall_lanes"

when isMainModule: main()
