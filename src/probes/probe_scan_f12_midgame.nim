## Scan F12 ebSt for mid/late story: party incl Poo, money, spine past fourside.
import
  std/[os, strformat, strutils, algorithm, options],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

proc gradePng(path: string) =
  let stOpt = extractState(cast[seq[uint8]](readFile(path)))
  if stOpt.isNone: return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  try: deserializeState(stOpt.get, snes, cpu)
  except CatchableError: return
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  let p0 = readU8(snes, PartySlot0)
  let p1 = readU8(snes, PartySlot1)
  let p2 = readU8(snes, PartySlot2)
  let p3 = readU8(snes, 0x988E)
  let money = readU16(snes, 0x9831)
  let story = readU8(snes, KnockCompleteOff)
  let fo = foursidePercent(snes)
  let ma = magicantPercent(snes)
  let wi = wintersPercent(snes)
  let hasJeff = partyHasChar(snes, PartyCharJeff)
  let hasPaula = partyHasChar(snes, PartyCharPaula)
  let hasPoo = p0 == 4 or p1 == 4 or p2 == 4 or p3 == 4
  # Interesting: midgame party, deep map, high money, or Poo
  if hasJeff or hasPaula or hasPoo or money >= 2000 or py >= 0x1000 or fo > 0:
    echo fmt"{extractFilename(path)}: pos=(0x{px:04X},0x{py:04X}) party={p0:02X},{p1:02X},{p2:02X},{p3:02X} $={money} $99F2={story:02X} w={wi} f={fo} m={ma} poo={hasPoo}"

proc main() =
  var paths: seq[string]
  for k in walkDir("/home/monofuel/Pictures/Screenshots"):
    if k.kind == pcFile and "earthbound_" in k.path and k.path.endsWith(".png"):
      if getFileSize(k.path) > 80_000:
        paths.add k.path
  # also secret archive if present
  let secret = "/home/monofuel/Documents/Projects/Sygnosphere/decompbound_secret/screenstates"
  if dirExists(secret):
    for k in walkDir(secret):
      if k.kind == pcFile and k.path.endsWith(".png") and getFileSize(k.path) > 80_000:
        paths.add k.path
  paths.sort()
  echo "scanning ", paths.len, " F12s"
  for p in paths:
    gradePng(p)

when isMainModule:
  main()
