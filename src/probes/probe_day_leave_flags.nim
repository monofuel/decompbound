## Diff WRAM event region night captain vs midgame slots for day/leave-Onett candidates.
import
  std/[os, strformat, strutils, tables, algorithm],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const FlagLo = 0x9800
const FlagHi = 0xA200

proc loadState(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, cpu)

proc snap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in FlagLo ..< FlagHi:
    result[off] = readU8(snes, off)

proc grade(path: string) =
  if not fileExists(path): return
  let snes = loadState(path)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{path}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X} kn={pokeyKnockPercent(snes)} $99F2={readU8(snes,0x99F2):02X} $9887={readU8(snes,0x9887):02X} fr={frankPercent(snes)} cs={captainStrongPercent(snes)}"

proc diff(aPath, bPath: string) =
  if not fileExists(aPath) or not fileExists(bPath): return
  let a = snap(loadState(aPath))
  let b = snap(loadState(bPath))
  var lines: seq[string]
  for off in FlagLo ..< FlagHi:
    let va = a.getOrDefault(off, 0)
    let vb = b.getOrDefault(off, 0)
    if va != vb:
      lines.add fmt"  ${off:04X}: 0x{va:02X}->0x{vb:02X}"
  echo fmt"DIFF {aPath} -> {bPath} ({lines.len} bytes)"
  for i, line in lines:
    if i < 60: echo line
  if lines.len > 60: echo "  ... +", lines.len - 60

proc main() =
  grade("bin/states/llm/captain_approach.state")
  grade("bin/states/llm/giant_approach.state")
  grade("bin/states/llm/post_knock_outdoor.state")
  grade("bin/states/slot1.state")
  grade("bin/states/slot85.state")
  grade("bin/states/battle_menu_healthy.state")
  # night knock-complete vs midgame with party
  if fileExists("bin/states/llm/captain_approach.state"):
    diff("bin/states/llm/captain_approach.state", "bin/states/slot1.state")
  if fileExists("bin/states/llm/post_knock_outdoor.state"):
    diff("bin/states/llm/post_knock_outdoor.state", "bin/states/llm/captain_approach.state")

when isMainModule: main()
