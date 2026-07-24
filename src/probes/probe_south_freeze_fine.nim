## d85d: fine bisect $1000-$10FF and $1F00-$1FFF for south freeze unlock.

import
  std/[os, strformat, sequtils],
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

proc withOverlay(fre: SnesBus; offs: openArray[int]): int =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  for off in offs:
    snes.bus.mem[0x7E0000 + off] = fre.bus.mem[0x7E0000 + off]
  snes.bus.mem[0x7E0000 + WorldXBase + i] = uint8(px and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + i + 1] = uint8(px shr 8)
  snes.bus.mem[0x7E0000 + WorldYBase + i] = uint8(py and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + i + 1] = uint8(py shr 8)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  pureRight(snes, c)

proc main() =
  let fre = newSnesBus(policy.readRomFile(Rom))
  var cf = fre.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), fre, cf)

  # Diff dump of unlocking regions
  echo "=== diffs freeze vs free in $1000-$10FF and $1F00-$1FFF ==="
  let frz = newSnesBus(policy.readRomFile(Rom))
  var cz = frz.resetCpu()
  deserializeState(cast[seq[byte]](readFile(FreezePath)), frz, cz)
  var diffs: seq[int] = @[]
  for off in 0x1000 .. 0x10FF:
    if readU8(frz, off) != readU8(fre, off):
      echo fmt"  ${off:04X}: freeze={readU8(frz,off):02X} free={readU8(fre,off):02X}"
      diffs.add off
  for off in 0x1F00 .. 0x1FFF:
    if readU8(frz, off) != readU8(fre, off):
      echo fmt"  ${off:04X}: freeze={readU8(frz,off):02X} free={readU8(fre,off):02X}"
      diffs.add off
  echo "diff_count=", diffs.len

  # 16-byte windows in each region
  echo "=== 16-byte windows $1000 ==="
  for base in countup(0x1000, 0x10F0, 16):
    var offs: seq[int] = @[]
    for o in base .. base+15: offs.add o
    let r = withOverlay(fre, offs)
    if r > 8: echo fmt"UNLOCK ${base:04X}..${base+15:04X} pureRight={r}"
    else: echo fmt"fail ${base:04X}..${base+15:04X}"

  echo "=== 16-byte windows $1F00 ==="
  for base in countup(0x1F00, 0x1FF0, 16):
    var offs: seq[int] = @[]
    for o in base .. base+15: offs.add o
    let r = withOverlay(fre, offs)
    if r > 8: echo fmt"UNLOCK ${base:04X}..${base+15:04X} pureRight={r}"
    else: echo fmt"fail ${base:04X}..${base+15:04X}"

  # Single-byte from diffs only
  echo "=== single-byte diffs ==="
  for off in diffs:
    let r = withOverlay(fre, [off])
    if r > 8:
      echo fmt"UNLOCK single ${off:04X} free={readU8(fre,off):02X} pureRight={r}"

  # All diffs together
  let rAll = withOverlay(fre, diffs)
  echo fmt"all diffs together pureRight={rAll}"

  # Each region alone (only diffs)
  var d10: seq[int] = @[]
  var d1f: seq[int] = @[]
  for off in diffs:
    if off <= 0x10FF: d10.add off
    else: d1f.add off
  echo fmt"diffs $1000 region only pureRight={withOverlay(fre, d10)} count={d10.len}"
  echo fmt"diffs $1F00 region only pureRight={withOverlay(fre, d1f)} count={d1f.len}"

  echo "OK probe_south_freeze_fine"

when isMainModule:
  main()
