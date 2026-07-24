## Diff event-flag WRAM between onett_start, post_knock indoor, post_knock outdoor synth.
import
  std/[os, strformat, strutils, tables, algorithm],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

const
  FlagLo = 0x9800
  FlagHi = 0xA000

proc snap(path: string): Table[int, int] =
  result = initTable[int, int]()
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  for off in FlagLo ..< FlagHi:
    result[off] = readU8(snes, off)
  # also print key metrics
  echo fmt"{path}: kn={pokeyKnockPercent(snes)} kc={knockComplete(snes)} party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X} $99F2={readU8(snes,0x99F2):02X}"

proc diff(a, b: Table[int, int]; label: string) =
  var lines: seq[string]
  for off in FlagLo ..< FlagHi:
    let va = a.getOrDefault(off, 0)
    let vb = b.getOrDefault(off, 0)
    if va != vb:
      lines.add fmt"  ${off:04X}: 0x{va:02X}->0x{vb:02X}"
  echo label, " diffs=", lines.len
  for i, line in lines:
    if i < 80: echo line
  if lines.len > 80: echo "  ... (", lines.len - 80, " more)"

proc main() =
  let a = snap("bin/states/llm/onett_start.state")
  let b = snap("bin/states/llm/post_knock.state")
  let c = snap("bin/states/llm/post_knock_outdoor.state")
  let d = snap("bin/states/llm/buzz_meteor_attempt.state")
  diff(a, b, "onett_start -> post_knock indoor")
  diff(b, c, "post_knock indoor -> outdoor synth")
  diff(c, d, "outdoor synth -> buzz meteor attempt")

when isMainModule: main()
