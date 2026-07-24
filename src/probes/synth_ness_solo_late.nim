## Extract solo-Ness late F12s as Magicant candidates (party 01 only + $99F2!=knock).
import
  std/[os, strformat, strutils, options, algorithm],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

proc tryPng(path: string) =
  if getFileSize(path) < 80_000: return
  let stOpt = extractState(cast[seq[uint8]](readFile(path)))
  if stOpt.isNone: return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  try: deserializeState(stOpt.get, snes, c)
  except CatchableError: return
  let p0 = readU8(snes, PartySlot0)
  let p1 = readU8(snes, PartySlot1)
  let p2 = readU8(snes, PartySlot2)
  let p3 = readU8(snes, PartySlot3)
  let story = readU8(snes, KnockCompleteOff)
  if p0 != PartyCharNess or p1 != 0 or p2 != 0: return
  if story == 0 or story == KnockCompleteVal: return
  let i = PlayerSlot * SlotIndexStride
  let money = readU16(snes, 0x9831)
  let lv = partyLeaderLevel(snes)
  echo fmt"{extractFilename(path)}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) party={p0:02X},{p1:02X},{p2:02X},{p3:02X} lv={lv} $={money} $99F2={story:02X} ma={magicantPercent(snes)} gi={giygasPercent(snes)}"
  # Keep highest level solo Ness as magicant candidate
  if lv >= 10 or money == 0:
    let outp = "bin/states/llm/ness_solo_late.state"
    writeFile(outp, cast[string](serializeState(snes, c)))
    echo "  WROTE ", outp

proc main() =
  var paths: seq[string]
  for k in walkDir("/home/monofuel/Pictures/Screenshots"):
    if k.kind == pcFile and "earthbound_" in k.path and k.path.endsWith(".png"):
      paths.add k.path
  paths.sort()
  for p in paths: tryPng(p)

when isMainModule: main()
