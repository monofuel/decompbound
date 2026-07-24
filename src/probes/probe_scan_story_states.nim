## Grade all bin/states/*.state + llm/* for party, knock, buzz, frank, giant, spine.
import
  std/[os, strformat, strutils, algorithm],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc grade(path: string) =
  if not fileExists(path): return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  try:
    deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  except CatchableError as e:
    echo path, " FAIL load: ", e.msg
    return
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase+i)
  let py = readU16(snes, WorldYBase+i)
  let pr0 = readU8(snes, 0x988B)
  let pr1 = readU8(snes, 0x988C)
  let pr2 = readU8(snes, 0x988D)
  let kn = pokeyKnockPercent(snes)
  let bb = buzzBuzzPercent(snes)
  let fr = frankPercent(snes)
  let gs = giantStepPercent(snes)
  let su = sunrisePercent(snes)
  let kc = knockComplete(snes)
  # only print interesting or all with compact line
  echo fmt"{path}: pos=(0x{px:04X},0x{py:04X}) party={pr0:02X},{pr1:02X},{pr2:02X} kn={kn} kc={kc} bb={bb} su={su} fr={fr} gs={gs} $9885={readU8(snes,0x9885):02X} $99F2={readU8(snes,0x99F2):02X}"

proc main() =
  var paths: seq[string]
  for p in walkDirRec("bin/states"):
    if p.endsWith(".state"): paths.add p
  paths.sort()
  for p in paths: grade(p)

when isMainModule: main()
