## Flag-diff high-bitpop F12s vs poo_very_deep soft ceiling (ma98/gi80).
## Hunts Magicant dream / Giygas phase bits still unset in fixtures.

import
  std/[os, strformat, strutils, tables, algorithm, options],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Base = "bin/states/llm/poo_very_deep.state"

proc loadState(path: string): SnesBus =
  ## Load .state or ebSt PNG into a fresh SNES bus.
  result = newSnesBus(policy.readRomFile(Rom))
  var c = result.resetCpu()
  if path.endsWith(".png"):
    let st = extractState(cast[seq[uint8]](readFile(path)))
    doAssert st.isSome, "no ebSt in " & path
    deserializeState(st.get, result, c)
  else:
    deserializeState(cast[seq[byte]](readFile(path)), result, c)

proc snapFlags(snes: SnesBus): Table[int, int] =
  ## Snapshot event/story WRAM window used by soft spine.
  result = initTable[int, int]()
  for off in 0x9880 .. 0x9BFF:
    result[off] = readU8(snes, off)

proc main() =
  ## Diff base soft ceiling against high-bp F12s; print unique set bits.
  doAssert fileExists(Base)
  let base = loadState(Base)
  echo "BASE ", Base, " ", checkpointSpineLine(base),
    " dream=", hasMagicantDreamFlag(base), " giygasFlag=", hasGiygasPhaseFlag(base),
    " sanctuarySoft=", hasAllSanctuarySoft(base)
  let baseFlags = snapFlags(base)

  let candidates = @[
    "/home/monofuel/Pictures/Screenshots/earthbound_20260723-233608.png", # bp667
    "/home/monofuel/Pictures/Screenshots/earthbound_20260724-002913.png", # bp639
    "/home/monofuel/Pictures/Screenshots/earthbound_20260724-000811.png", # fo90 ma98
    "/home/monofuel/Pictures/Screenshots/earthbound_20260723-235119.png", # bp622
    "/home/monofuel/Pictures/Screenshots/earthbound_20260724-011033.png", # indoor? bp631
  ]
  for path in candidates:
    if not fileExists(path):
      echo "SKIP missing ", path
      continue
    let snes = loadState(path)
    echo "=== ", extractFilename(path), " ", checkpointSpineLine(snes),
      " dream=", hasMagicantDreamFlag(snes), " giygasFlag=", hasGiygasPhaseFlag(snes)
    let fl = snapFlags(snes)
    var onlyThem: seq[string]
    var onlyBase: seq[string]
    var diffs: seq[string]
    for off, va in baseFlags:
      let vb = fl.getOrDefault(off, va)
      if va != vb:
        let line = fmt"${off:04X}: 0x{va:02X}->0x{vb:02X}"
        diffs.add line
        # Bits set in F12 not in base
        let gained = vb and (not va)
        if gained != 0:
          onlyThem.add fmt"${off:04X} +0x{gained:02X} (now 0x{vb:02X})"
        let lost = va and (not vb)
        if lost != 0:
          onlyBase.add fmt"${off:04X} -0x{lost:02X}"
    echo "  flagdiffs=", diffs.len, " gained_bits=", onlyThem.len
    for i, s in onlyThem:
      if i < 24: echo "  GAIN ", s
    for i, s in diffs:
      if i < 12: echo "  DIFF ", s
  echo "OK probe_magicant_flagdiff"

when isMainModule:
  main()
