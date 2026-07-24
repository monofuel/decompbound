## Grade earthbound F12 PNGs with ebSt for party + story percents (read-only).
import
  std/[os, strformat, strutils, algorithm, options],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

proc gradePng(path: string) =
  let png = cast[seq[uint8]](readFile(path))
  let stOpt = extractState(png)
  if stOpt.isNone:
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  try:
    deserializeState(stOpt.get, snes, cpu)
  except CatchableError:
    echo extractFilename(path), " load fail"
    return
  let i = PlayerSlot * SlotIndexStride
  let pr0 = readU8(snes, 0x988B)
  let pr1 = readU8(snes, 0x988C)
  let pr2 = readU8(snes, 0x988D)
  let pr3 = readU8(snes, 0x988E)
  echo fmt"{extractFilename(path)}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"party={pr0:02X},{pr1:02X},{pr2:02X},{pr3:02X} kn={pokeyKnockPercent(snes)} " &
    fmt"kc={knockComplete(snes)} bb={buzzBuzzPercent(snes)} su={sunrisePercent(snes)} " &
    fmt"fr={frankPercent(snes)} gs={giantStepPercent(snes)} fo={foursidePercent(snes)} " &
    fmt"ma={magicantPercent(snes)} gi={giygasPercent(snes)} bp={eventFlagBitPop(snes)} " &
    fmt"lv={readU8(snes,PartyLeaderLevelOff)} $99F2={readU8(snes,0x99F2):02X}"

proc main() =
  let dir = "/home/monofuel/Pictures/Screenshots"
  var paths: seq[string]
  for k in walkDir(dir):
    if k.kind == pcFile and "earthbound_" in k.path and k.path.endsWith(".png"):
      if getFileSize(k.path) > 80_000:
        paths.add k.path
  paths.sort()
  let start = max(0, paths.len - 40)
  for i in start ..< paths.len:
    gradePng(paths[i])

when isMainModule: main()
