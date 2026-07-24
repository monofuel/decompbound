## Deep leave-Onett RE: grade F12s + fixtures for captain past soft-70.
## Looks for Paula/Jeff party, $99F2 progression, and map/pos outliers vs night captain.

import
  std/[os, strformat, strutils, algorithm, options, tables],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  ShotDir = "/home/monofuel/Pictures/Screenshots"
  Watch = [
    0x9885, 0x9887, 0x988B, 0x988C, 0x988D, 0x988E, 0x98A3, 0x98A4,
    0x98B8, 0x99F2, 0x9831, 0x9A0B, 0x9A0F, 0x9A10
  ]

proc gradeState(snes: SnesBus; label: string) =
  ## Print spine + watch bytes for one machine image.
  let i = PlayerSlot * SlotIndexStride
  echo fmt"=== {label} ==="
  echo fmt"  pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"cs={captainStrongPercent(snes)} paula={paulaRescuePercent(snes)} " &
    fmt"winters={wintersPercent(snes)} fo={foursidePercent(snes)}"
  echo fmt"  party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X}," &
    fmt"{readU8(snes,0x988D):02X},{readU8(snes,0x988E):02X} " &
    fmt"lv={partyLeaderLevel(snes)} size={partySize(snes)} " &
    fmt"paulaIn={partyHasChar(snes, PartyCharPaula)} jeffIn={partyHasChar(snes, PartyCharJeff)}"
  for off in Watch:
    echo fmt"  ${off:04X}=0x{readU8(snes,off):02X}"
  echo "  ", checkpointSpineLine(snes)

proc loadState(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile(Rom))
  var c = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, c)

proc loadPng(path: string): Option[SnesBus] =
  let st = extractState(cast[seq[uint8]](readFile(path)))
  if st.isNone: return none(SnesBus)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  try:
    deserializeState(st.get, snes, c)
  except CatchableError:
    return none(SnesBus)
  some(snes)

proc main() =
  ## Diff night captain vs midgame/later; scan F12s for leave candidates.
  doAssert fileExists(Rom)
  echo "=== FIXTURES ==="
  for p in [
    "bin/states/llm/captain_west.state",
    "bin/states/llm/captain_approach.state",
    "bin/states/llm/giant_approach.state",
    "bin/states/llm/midgame_approach.state",
    "bin/states/llm/midgame_deep.state",
    "bin/states/slot1.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/fourside80_walkable.state"
  ]:
    if fileExists(p):
      gradeState(loadState(p), extractFilename(p))

  # Flagdiff captain_west (night cs50) vs midgame (cs70)
  if fileExists("bin/states/llm/captain_west.state") and
      fileExists("bin/states/llm/midgame_approach.state"):
    let night = loadState("bin/states/llm/captain_west.state")
    let mid = loadState("bin/states/llm/midgame_approach.state")
    echo "=== FLAGDIFF night captain_west -> midgame_approach ($9880..$9BFF) ==="
    var n = 0
    for off in 0x9880 .. 0x9BFF:
      let a = readU8(night, off)
      let b = readU8(mid, off)
      if a != b:
        if n < 40:
          echo fmt"  ${off:04X}: 0x{a:02X}->0x{b:02X}"
        n.inc
    echo "total_diffs=", n

  # F12: Paula in party and later story — leave-Onett soft candidates
  echo "=== F12 leave candidates (Paula+ later $99F2 or Jeff) ==="
  var paths: seq[string]
  for k in walkDir(ShotDir):
    if k.kind == pcFile and "earthbound_" in k.path and k.path.endsWith(".png"):
      if getFileSize(k.path) > 80_000:
        paths.add k.path
  paths.sort()
  let start = max(0, paths.len - 80)
  var hits = 0
  for i in start ..< paths.len:
    let snOpt = loadPng(paths[i])
    if snOpt.isNone: continue
    let snes = snOpt.get
    let story = readU8(snes, KnockCompleteOff)
    let later = story != 0 and story != KnockCompleteVal
    let hasP = partyHasChar(snes, PartyCharPaula)
    let hasJ = partyHasChar(snes, PartyCharJeff)
    if (hasP and later) or hasJ:
      let idx = PlayerSlot * SlotIndexStride
      echo fmt"{extractFilename(paths[i])}: cs={captainStrongPercent(snes)} " &
        fmt"paula={paulaRescuePercent(snes)} winters={wintersPercent(snes)} " &
        fmt"$99F2=0x{story:02X} party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X}," &
        fmt"{readU8(snes,0x988D):02X} pos=(0x{readU16(snes,WorldXBase+idx):04X}," &
        fmt"0x{readU16(snes,WorldYBase+idx):04X})"
      hits.inc
      if hits >= 25: break
  echo "leave_candidate_hits=", hits
  echo "OK probe_leave_onett_deep"

when isMainModule:
  main()
