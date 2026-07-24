## Scan recent F12 ebSt for day/party/knock/buzz/frank + candidate day flags.
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
  let px = readU16(snes, WorldXBase+i)
  let py = readU16(snes, WorldYBase+i)
  let pr0 = readU8(snes, 0x988B)
  let pr1 = readU8(snes, 0x988C)
  let kn = pokeyKnockPercent(snes)
  let bb = buzzBuzzPercent(snes)
  let su = sunrisePercent(snes)
  let fr = frankPercent(snes)
  let gs = giantStepPercent(snes)
  let cs = captainStrongPercent(snes)
  # only print if knock-related or Onett outdoor night-ish or day-ish metrics
  if kn >= 50 or bb > 0 or su > 0 or fr > 0 or (px < 0x1C00 and py < 0x0400):
    echo fmt"{extractFilename(path)}: pos=(0x{px:04X},0x{py:04X}) party={pr0:02X},{pr1:02X} kn={kn} kc={knockComplete(snes)} bb={bb} su={su} fr={fr} gs={gs} cs={cs} $9887={readU8(snes,0x9887):02X} $99F2={readU8(snes,0x99F2):02X} $9885={readU8(snes,0x9885):02X}"

proc main() =
  var paths: seq[string]
  for k in walkDir("/home/monofuel/Pictures/Screenshots"):
    if k.kind == pcFile and "earthbound_" in k.path and k.path.endsWith(".png"):
      if getFileSize(k.path) > 80_000: paths.add k.path
  paths.sort()
  let start = max(0, paths.len - 60)
  for i in start ..< paths.len:
    gradePng(paths[i])

when isMainModule: main()
