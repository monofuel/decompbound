## Scan available states for party composition + spine (find Poo / late-game).
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc main() =
  var paths: seq[string]
  for kind, path in walkDir("bin/states"):
    if kind == pcFile and path.endsWith(".state"):
      paths.add path
  for kind, path in walkDir("bin/states/llm"):
    if kind == pcFile and path.endsWith(".state"):
      paths.add path
  for path in paths:
    let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
    var cpu = snes.resetCpu()
    try:
      deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
    except CatchableError:
      continue
    let p0 = readU8(snes, PartySlot0)
    let p1 = readU8(snes, PartySlot1)
    let p2 = readU8(snes, PartySlot2)
    let money = readU16(snes, 0x9831)
    let story = readU8(snes, KnockCompleteOff)
    # Only print non-trivial / interesting
    if p1 != 0 or p2 != 0 or money > 100 or (story != 0 and story != KnockCompleteVal):
      let i = PlayerSlot * SlotIndexStride
      echo fmt"{extractFilename(path)}: party={p0:02X},{p1:02X},{p2:02X} $99F2={story:02X} $={money} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) w={wintersPercent(snes)} b={belchPercent(snes)} f={foursidePercent(snes)} m={magicantPercent(snes)}"

when isMainModule: main()
