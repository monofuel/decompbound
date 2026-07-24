## d85c: binary search which free WRAM bands unlock south freeze.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Giant = "bin/states/llm/giant_approach.state"
  FreezePath = "bin/states/llm/south_freeze_fr90.state"

proc pureRight(snes: SnesBus; c: var Cpu; frames = 200): int =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  let px0 = int(readU16(snes, WorldXBase + i))
  for f in 1 .. frames:
    snes.joy1 = 0x0100'u16
    policy.stepOneFrame(snes, c, img)
  abs(int(readU16(snes, WorldXBase + i)) - px0)

proc trialBands(fre: SnesBus; name: string; bands: openArray[(int, int)]): int =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  for (lo, hi) in bands:
    for off in lo .. hi:
      snes.bus.mem[0x7E0000 + off] = fre.bus.mem[0x7E0000 + off]
  # restore freeze pos + knock
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(px and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(px shr 8)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(py and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(py shr 8)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  result = pureRight(snes, c)
  let mark = if result > 8: "UNLOCK" else: "fail"
  echo fmt"{mark} {name} pureRight={result}"

proc main() =
  doAssert fileExists(FreezePath)
  let fre = newSnesBus(policy.readRomFile(Rom))
  var cf = fre.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), fre, cf)

  # Coarse 4K bands over 0x0000-0xFFFF
  echo "=== coarse 4K bands ==="
  var unlocked: seq[(int, int)] = @[]
  var lo = 0
  while lo < 0x10000:
    let hi = min(lo + 0x0FFF, 0xFFFF)
    let name = fmt"${lo:04X}..${hi:04X}"
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    for off in lo .. hi:
      snes.bus.mem[0x7E0000 + off] = fre.bus.mem[0x7E0000 + off]
    snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(px and 0xFF)
    snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(px shr 8)
    snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(py and 0xFF)
    snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(py shr 8)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
    snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
    let r = pureRight(snes, c)
    let mark = if r > 8: "UNLOCK" else: "fail"
    echo fmt"{mark} {name} pureRight={r}"
    if r > 8:
      unlocked.add (lo, hi)
    lo += 0x1000

  # Bisect unlocked bands to 256-byte windows
  echo "=== fine 256-byte within unlocked ==="
  for (blo, bhi) in unlocked:
    var o = blo
    while o <= bhi:
      let hi = min(o + 0xFF, bhi)
      discard trialBands(fre, fmt"${o:04X}..${hi:04X}", [(o, hi)])
      o += 0x100

  # Combine all unlocked 4K bands
  if unlocked.len > 0:
    discard trialBands(fre, "all unlocked 4K combined", unlocked)

  echo "OK probe_south_freeze_bisect"

when isMainModule:
  main()
