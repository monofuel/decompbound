## d85b: WRAM unlock trials for south commercial freeze (serialized seat).

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  FreezePath = "bin/states/llm/south_freeze_fr90.state"

proc loadFreeze(): (SnesBus, Cpu) =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
  (snes, c)

proc mobility(snes: SnesBus; c: var Cpu; frames = 300): int =
  ## Bounding-box span under directional pad thrash (not net displacement).
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  var minX = readU16(snes, WorldXBase + i)
  var maxX = minX
  var minY = readU16(snes, WorldYBase + i)
  var maxY = minY
  for f in 1 .. frames:
    case f mod 4
    of 0: snes.joy1 = 0x0200'u16
    of 1: snes.joy1 = 0x0800'u16
    of 2: snes.joy1 = 0x0100'u16
    else: snes.joy1 = 0x0400'u16
    policy.stepOneFrame(snes, c, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if px < minX: minX = px
    if px > maxX: maxX = px
    if py < minY: minY = py
    if py > maxY: maxY = py
  (maxX - minX) + (maxY - minY)

proc pureDir(snes: SnesBus; c: var Cpu; joy: uint16; frames = 200): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let px0 = int(readU16(snes, WorldXBase + i))
  let py0 = int(readU16(snes, WorldYBase + i))
  for f in 1 .. frames:
    snes.joy1 = joy
    policy.stepOneFrame(snes, c, img)
  abs(int(readU16(snes, WorldXBase + i)) - px0) + abs(int(readU16(snes, WorldYBase + i)) - py0)

proc trial(fre: SnesBus; name: string; apply: proc(snes: SnesBus)) =
  var (snes, c) = loadFreeze()
  apply(snes)
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8958] = 0xFF
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let span = mobility(snes, c)
  let right = pureDir(snes, c, 0x0100'u16, 150)
  let mark = if span > 4 or right > 4: "UNLOCK" else: "fail"
  echo fmt"{mark} {name} bbox={span} pureRight={right}"

proc main() =
  doAssert fileExists(FreezePath), "need south_freeze_fr90.state"
  let fre = newSnesBus(policy.readRomFile(Rom))
  var cf = fre.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), fre, cf)

  # control
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    echo fmt"CONTROL free giant bbox={mobility(snes,c)} pureRight={pureDir(snes,c,0x0100'u16)}"
  block:
    var (snes, c) = loadFreeze()
    echo fmt"CONTROL freeze bbox={mobility(snes,c)} pureRight={pureDir(snes,c,0x0100'u16)} 8650={readU8(snes,0x8650):02X}"

  trial(fre, "baseline+winFF", proc(s: SnesBus) = discard)

  for off in [0x0024, 0x0025, 0x5DB6, 0x5E73, 0x9877, 0x0BD0, 0x0BD1, 0x0B1F, 0x0B59]:
    let o = off
    trial(fre, fmt"single ${o:04X}", proc(s: SnesBus) =
      s.bus.mem[0x7E0000 + o] = uint8(readU8(fre, o)))

  trial(fre, "region low", proc(s: SnesBus) =
    for off in 0x0000 .. 0x00FF: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off)))
  trial(fre, "region mode", proc(s: SnesBus) =
    for off in 0x5D00 .. 0x5FFF: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off)))
  trial(fre, "region entity keep pos", proc(s: SnesBus) =
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(s, WorldXBase+i); let py = readU16(s, WorldYBase+i)
    for off in 0x0B00 .. 0x0D00: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    s.bus.mem[0x7E0000+WorldXBase+i]=uint8(px and 0xFF)
    s.bus.mem[0x7E0000+WorldXBase+i+1]=uint8(px shr 8)
    s.bus.mem[0x7E0000+WorldYBase+i]=uint8(py and 0xFF)
    s.bus.mem[0x7E0000+WorldYBase+i+1]=uint8(py shr 8))
  trial(fre, "region hitbox", proc(s: SnesBus) =
    for off in 0x2B00 .. 0x2C80: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off)))
  trial(fre, "region windows", proc(s: SnesBus) =
    for off in 0x8600 .. 0x8A00: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off)))
  trial(fre, "region flags keep knock", proc(s: SnesBus) =
    for off in 0x9800 .. 0x9C00: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    s.bus.mem[0x7E0000+KnockCompleteOff]=KnockCompleteVal.uint8
    s.bus.mem[0x7E0000+KnockStoryFlagOff]=KnockStoryFlagVal.uint8)

  trial(fre, "low+mode", proc(s: SnesBus) =
    for off in 0x0000 .. 0x00FF: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    for off in 0x5D00 .. 0x5FFF: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off)))

  trial(fre, "low+mode+entity+hitbox+win", proc(s: SnesBus) =
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(s, WorldXBase+i); let py = readU16(s, WorldYBase+i)
    for off in 0x0000 .. 0x00FF: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    for off in 0x5D00 .. 0x5FFF: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    for off in 0x0B00 .. 0x0D00: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    for off in 0x2B00 .. 0x2C80: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    for off in 0x8600 .. 0x8A00: s.bus.mem[0x7E0000+off]=uint8(readU8(fre,off))
    s.bus.mem[0x7E0000+WorldXBase+i]=uint8(px and 0xFF)
    s.bus.mem[0x7E0000+WorldXBase+i+1]=uint8(px shr 8)
    s.bus.mem[0x7E0000+WorldYBase+i]=uint8(py and 0xFF)
    s.bus.mem[0x7E0000+WorldYBase+i+1]=uint8(py shr 8)
    s.bus.mem[0x7E0000+KnockCompleteOff]=KnockCompleteVal.uint8)

  trial(fre, "almost full free WRAM keep knock+pos", proc(s: SnesBus) =
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(s, WorldXBase+i); let py = readU16(s, WorldYBase+i)
    # Copy free state wholesale then restore freeze pos + knock
    # (load free then poke pos from freeze)
    discard
  )

  # Load free, set freeze pos only — proves pos is walkable under free control state
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Giant)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    # freeze coords
    snes.bus.mem[0x7E0000+WorldXBase+i]=0x21
    snes.bus.mem[0x7E0000+WorldXBase+i+1]=0x09
    snes.bus.mem[0x7E0000+WorldYBase+i]=0xA0
    snes.bus.mem[0x7E0000+WorldYBase+i+1]=0x02
    snes.bus.mem[0x7E0000+KnockCompleteOff]=KnockCompleteVal.uint8
    for f in 1..20:
      snes.joy1=0
      let img=newImage(ppu.ScreenWidth,ppu.ScreenHeight)
      policy.stepOneFrame(snes,c,img)
    let img=newImage(ppu.ScreenWidth,ppu.ScreenHeight)
    let r = pureDir(snes, c, 0x0100'u16, 200)
    let l = pureDir(snes, c, 0x0200'u16, 200)
    let u = pureDir(snes, c, 0x0800'u16, 200)
    echo fmt"free control @ freeze pos pureRight={r} afterL={l} afterU={u} end=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"

  # Load freeze, load free full state via deserialize of free then restore nothing - vs
  # freeze full bytes except copy free everything from fre mem
  block:
    var (snes, c) = loadFreeze()
    # Overlay ALL free WRAM 0x0000-0xFFFF except player pos
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase+i); let py = readU16(snes, WorldYBase+i)
    for off in 0x0000 .. 0xFFFF:
      snes.bus.mem[0x7E0000 + off] = fre.bus.mem[0x7E0000 + off]
    snes.bus.mem[0x7E0000+WorldXBase+i]=uint8(px and 0xFF)
    snes.bus.mem[0x7E0000+WorldXBase+i+1]=uint8(px shr 8)
    snes.bus.mem[0x7E0000+WorldYBase+i]=uint8(py and 0xFF)
    snes.bus.mem[0x7E0000+WorldYBase+i+1]=uint8(py shr 8)
    snes.bus.mem[0x7E0000+KnockCompleteOff]=KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000+KnockStoryFlagOff]=KnockStoryFlagVal.uint8
    let span = mobility(snes, c)
    let r = pureDir(snes, c, 0x0100'u16, 200)
    echo fmt"FULL free WRAM keep freeze pos bbox={span} pureRight={r}"

  echo "OK probe_south_freeze_unlock"

when isMainModule:
  main()
