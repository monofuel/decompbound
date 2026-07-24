## Diff WRAM between pre_knock_bed and post_knock to pin knock completion flag.
import
  std/[os, strformat, strutils, algorithm],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc main() =
  ## Byte-diff 7E WRAM of two fixtures; print stable non-pos candidates.
  let rom = "bin/Earthbound (U) [!].smc"
  let prePath = "bin/states/llm/pre_knock_bed.state"
  let postPath = "bin/states/llm/post_knock.state"
  if not fileExists(rom) or not fileExists(prePath) or not fileExists(postPath):
    echo "SKIP missing files"
    quit(0)
  let snesA = newSnesBus(policy.readRomFile(rom))
  let snesB = newSnesBus(policy.readRomFile(rom))
  var cA = snesA.resetCpu()
  var cB = snesB.resetCpu()
  deserializeState(cast[seq[byte]](readFile(prePath)), snesA, cA)
  deserializeState(cast[seq[byte]](readFile(postPath)), snesB, cB)
  echo "pre  knock=", pokeyKnockPercent(snesA), " tg=", touchGrassPercent(snesA),
    " room=", currentRoomLabel(snesA)
  echo "post knock=", pokeyKnockPercent(snesB), " tg=", touchGrassPercent(snesB),
    " room=", currentRoomLabel(snesB)
  # Diff WRAM $0000..$FFFF (bus mem is full map; use 7E mirror via mem)
  var diffs: seq[string]
  const WramBase = 0x7E0000
  for off in 0 .. 0xFFFF:
    let ea = WramBase + off
    if ea >= snesA.bus.mem.len: break
    let a = snesA.bus.mem[ea]
    let b = snesB.bus.mem[ea]
    if a != b:
      # skip entity position arrays (noisy)
      if off >= 0x0B8E and off < 0x0C40: continue
      diffs.add fmt"7E:{off:04X} {a:02X}->{b:02X}"
  echo "diff_count_filtered=", diffs.len
  for i, d in diffs:
    if i >= 80: break
    echo d
  # Highlight story-flag region $9800..$9BFF
  echo "--- flag region $9800..$9BFF ---"
  for off in 0x9800 .. 0x9BFF:
    let ea = WramBase + off
    let a = snesA.bus.mem[ea]
    let b = snesB.bus.mem[ea]
    if a != b:
      echo fmt"7E:{off:04X} {a:02X}->{b:02X}"

when isMainModule: main()
