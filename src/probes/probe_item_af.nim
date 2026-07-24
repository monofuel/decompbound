## Track candidate Sound Stone id 0xAF and late-story stable flag bits.
import
  std/[os, strformat, strutils, sequtils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc findByte(snes: SnesBus, target: int, lo, hi: int): seq[int] =
  for off in lo ..< hi:
    if readU8(snes, off) == target:
      result.add off

proc bitPop(snes: SnesBus, lo, hi: int): int =
  for off in lo ..< hi:
    var v = readU8(snes, off)
    while v > 0:
      if (v and 1) != 0: result.inc
      v = v shr 1

proc loadPath(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, c)

proc main() =
  let files = @[
    "bin/states/llm/bedroom.state",
    "bin/states/llm/onett_start.state",
    "bin/states/llm/post_knock_outdoor.state",
    "bin/states/llm/buzz_meteor.state",
    "bin/states/llm/captain_west.state",
    "bin/states/llm/midgame_approach.state",
    "bin/states/llm/fourside_deep_prepoo.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/poo_deep_south.state",
    "bin/states/llm/poo_very_deep.state",
    "bin/states/llm/poo_solo.state",
    "bin/states/llm/ness_solo_late.state"
  ]
  for p in files:
    if not fileExists(p): continue
    let snes = loadPath(p)
    let af = findByte(snes, 0xAF, 0x9800, 0x9C00)
    let bp = bitPop(snes, 0x9A00, 0x9C00)
    var afs = ""
    for off in af:
      if afs.len > 0: afs.add ","
      afs.add fmt"${off:04X}"
    echo extractFilename(p), ": bitpop9A=", bp, " AF@[", afs, "] lv=",
      partyLeaderLevel(snes), " size=", partySize(snes), " ma=",
      magicantPercent(snes), " gi=", giygasPercent(snes)

  let mid = loadPath("bin/states/llm/midgame_approach.state")
  let very = loadPath("bin/states/llm/poo_very_deep.state")
  let deep = loadPath("bin/states/llm/poo_deep_south.state")
  let poo = loadPath("bin/states/llm/poo_joined.state")
  let pre = loadPath("bin/states/llm/fourside_deep_prepoo.state")

  echo "--- late-story bits: set in poo+deep+very, clear in mid ---"
  var lateBits: seq[string]
  for off in 0x9A00 .. 0x9BFF:
    for bit in 0 .. 7:
      let mask = 1 shl bit
      let vm = readU8(mid, off) and mask
      let vv = readU8(very, off) and mask
      let vd = readU8(deep, off) and mask
      let vp = readU8(poo, off) and mask
      if vm == 0 and vv != 0 and vd != 0 and vp != 0:
        lateBits.add fmt"${off:04X}.b{bit}"
  for i, s in lateBits:
    if i < 50: echo "  ", s
  echo "late_story_bits=", lateBits.len

  echo "--- post-Jeff bits: set in mid+pre+poo+very, clear in captain night ---"
  let cap = loadPath("bin/states/llm/captain_west.state")
  var midBits: seq[string]
  for off in 0x9A00 .. 0x9BFF:
    for bit in 0 .. 7:
      let mask = 1 shl bit
      let vc = readU8(cap, off) and mask
      let vm = readU8(mid, off) and mask
      let vpre = readU8(pre, off) and mask
      let vp = readU8(poo, off) and mask
      let vv = readU8(very, off) and mask
      if vc == 0 and vm != 0 and vpre != 0 and vp != 0 and vv != 0:
        midBits.add fmt"${off:04X}.b{bit}"
  for i, s in midBits:
    if i < 40: echo "  ", s
  echo "post_jeff_stable_bits=", midBits.len

  # Bitpop thresholds as soft progress (documented RE observation)
  echo "BITPOP: captain=", bitPop(cap, 0x9A00, 0x9C00),
    " mid=", bitPop(mid, 0x9A00, 0x9C00),
    " prepoo=", bitPop(pre, 0x9A00, 0x9C00),
    " poo=", bitPop(poo, 0x9A00, 0x9C00),
    " deep=", bitPop(deep, 0x9A00, 0x9C00),
    " very=", bitPop(very, 0x9A00, 0x9C00)
  echo "OK probe_item_af"

when isMainModule:
  main()
