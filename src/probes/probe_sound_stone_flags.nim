## RE Sound Stone / sanctuary / Magicant candidates across fixtures.
## Strategy:
##  1) Item-byte sets: early (no stone) vs post-knock/buzz (has stone after Buzz)
##  2) Flag bitfields: midgame Jeff vs late Poo vs free-walk
##  3) Solo Ness late (ness_solo_late) vs full-party late
## Report only offsets with multi-fixture evidence — no inventing.

import
  std/[os, strformat, strutils, tables, sets, algorithm, sequtils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const Rom = "bin/Earthbound (U) [!].smc"

proc load(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile(Rom))
  var c = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, c)

proc flagMap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in 0x9880 .. 0x9C00:
    result[off] = readU8(snes, off)

proc itemBytes(snes: SnesBus): HashSet[int] =
  ## Collect candidate item-id bytes from party/stat region (hypothesis scan).
  result = initHashSet[int]()
  for off in 0x98C0 .. 0x99F0:
    let v = readU8(snes, off)
    if v >= 0x01 and v <= 0xEF:
      result.incl v

proc diffMaps(a, b: Table[int, int]; label: string; maxShow = 40) =
  var diffs: seq[(int, int, int)]
  for off, va in a:
    let vb = b.getOrDefault(off, va)
    if va != vb:
      diffs.add (off, va, vb)
  diffs.sort(proc (x, y: (int, int, int)): int = cmp(x[0], y[0]))
  echo fmt"--- {label} diffs={diffs.len} ---"
  for i, d in diffs:
    if i >= maxShow: break
    echo fmt"  ${d[0]:04X}: 0x{d[1]:02X}->0x{d[2]:02X}"

proc main() =
  let paths = {
    "cold": "bin/states/llm/bedroom.state",
    "onett": "bin/states/llm/onett_start.state",
    "postknock": "bin/states/llm/post_knock.state",
    "outdoor": "bin/states/llm/post_knock_outdoor.state",
    "buzz": "bin/states/llm/buzz_meteor.state",
    "captain": "bin/states/llm/captain_west.state",
    "mid": "bin/states/llm/midgame_approach.state",
    "prepoo": "bin/states/llm/fourside_deep_prepoo.state",
    "poo": "bin/states/llm/poo_joined.state",
    "deep": "bin/states/llm/poo_deep_south.state",
    "very": "bin/states/llm/poo_very_deep.state",
    "walk": "bin/states/llm/poo_endgame_walk.state",
    "solo_poo": "bin/states/llm/poo_solo.state",
    "solo_ness": "bin/states/llm/ness_solo_late.state"
  }.toTable

  var snes: Table[string, SnesBus]
  var flags: Table[string, Table[int, int]]
  var items: Table[string, HashSet[int]]
  for k, p in paths:
    if not fileExists(p):
      echo "SKIP ", k, " ", p
      continue
    let s = load(p)
    snes[k] = s
    flags[k] = flagMap(s)
    items[k] = itemBytes(s)
    let i = PlayerSlot * SlotIndexStride
    echo fmt"{k}: pos=(0x{readU16(s,WorldXBase+i):04X},0x{readU16(s,WorldYBase+i):04X}) " &
      fmt"party={readU8(s,0x988B):02X},{readU8(s,0x988C):02X},{readU8(s,0x988D):02X},{readU8(s,0x988E):02X} " &
      fmt"lv={partyLeaderLevel(s)} size={partySize(s)} $99F2={readU8(s,KnockCompleteOff):02X} " &
      fmt"ma={magicantPercent(s)} gi={giygasPercent(s)} items={items[k].len}"

  # Sound Stone candidates: in outdoor/buzz/captain but not cold bedroom
  if items.hasKey("cold") and items.hasKey("captain"):
    var onlyCap: seq[int]
    for x in items["captain"]:
      if x notin items["cold"]: onlyCap.add x
    onlyCap.sort()
    echo "items captain_not_cold: ", onlyCap.mapIt(fmt"0x{it:02X}").join(" ")
  if items.hasKey("mid") and items.hasKey("very"):
    var onlyLate: seq[int]
    for x in items["very"]:
      if x notin items["mid"]: onlyLate.add x
    onlyLate.sort()
    echo "items very_not_mid: ", onlyLate.mapIt(fmt"0x{it:02X}").join(" ")
  if items.hasKey("poo") and items.hasKey("very"):
    var onlyVery: seq[int]
    for x in items["very"]:
      if x notin items["poo"]: onlyVery.add x
    onlyVery.sort()
    echo "items very_not_poo_joined: ", onlyVery.mapIt(fmt"0x{it:02X}").join(" ")

  # Pairwise flag diffs of interest
  if flags.hasKey("cold") and flags.hasKey("captain"):
    diffMaps(flags["cold"], flags["captain"], "cold->captain", 30)
  if flags.hasKey("mid") and flags.hasKey("very"):
    diffMaps(flags["mid"], flags["very"], "mid->very", 50)
  if flags.hasKey("poo") and flags.hasKey("very"):
    diffMaps(flags["poo"], flags["very"], "poo_joined->very", 40)
  if flags.hasKey("very") and flags.hasKey("walk"):
    diffMaps(flags["very"], flags["walk"], "very->walk", 30)
  if flags.hasKey("solo_ness") and flags.hasKey("very"):
    diffMaps(flags["solo_ness"], flags["very"], "solo_ness->very", 30)
  if flags.hasKey("solo_poo") and flags.hasKey("poo"):
    diffMaps(flags["solo_poo"], flags["poo"], "solo_poo->poo_joined", 20)

  # Monotonic flag bytes: value increases cold < captain < mid < very
  if flags.hasKey("cold") and flags.hasKey("captain") and flags.hasKey("mid") and
      flags.hasKey("very"):
    echo "--- monotonic cold<=captain<=mid<=very (strict somewhere) ---"
    var mono: seq[int]
    for off in 0x9880 .. 0x9BFF:
      let a = flags["cold"].getOrDefault(off, 0)
      let b = flags["captain"].getOrDefault(off, 0)
      let c = flags["mid"].getOrDefault(off, 0)
      let d = flags["very"].getOrDefault(off, 0)
      if a <= b and b <= c and c <= d and (a < d):
        # skip pure noise ranges that change every frame-like
        if d - a >= 1 and d <= 0xFE:
          mono.add off
    for off in mono[0 .. min(40, mono.high)]:
      let va = flags["cold"].getOrDefault(off, 0)
      let vb = flags["captain"].getOrDefault(off, 0)
      let vc = flags["mid"].getOrDefault(off, 0)
      let vd = flags["very"].getOrDefault(off, 0)
      echo fmt"  ${off:04X}: {va:02X} {vb:02X} {vc:02X} {vd:02X}"
    echo "monotonic_count=", mono.len

  # Bit-count of $9Axx..$9Bxx as progress proxy
  for k in ["cold", "captain", "mid", "poo", "very", "solo_ness"]:
    if not flags.hasKey(k): continue
    var bits = 0
    for off in 0x9A00 .. 0x9BFF:
      var v = flags[k].getOrDefault(off, 0)
      while v > 0:
        if (v and 1) != 0: bits.inc
        v = v shr 1
    echo fmt"bitpop {k} $9A00..$9BFF = {bits}"

  echo "OK probe_sound_stone_flags"

when isMainModule:
  main()
