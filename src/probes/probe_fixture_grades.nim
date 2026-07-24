## Print story percents for all bin/states/llm fixtures.
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents, scene]

proc main() =
  ## Grade every llm fixture for campaign iteration.
  let rom = "bin/Earthbound (U) [!].smc"
  if not fileExists(rom):
    echo "SKIP no rom"; return
  let snes = newSnesBus(policy.readRomFile(rom))
  var c = snes.resetCpu()
  for kind in walkDir("bin/states/llm"):
    if kind.kind != pcFile or not kind.path.endsWith(".state"): continue
    deserializeState(cast[seq[byte]](readFile(kind.path)), snes, c)
    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    echo fmt"{kind.path.splitPath.tail}: tg={touchGrassPercent(snes)} pokey={pokeyPercent(snes)} knock={pokeyKnockPercent(snes)} room={currentRoomLabel(snes)} pos=(0x{px:04X},0x{py:04X})"

when isMainModule: main()
