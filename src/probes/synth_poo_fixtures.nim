## Extract Poo-era F12 ebSt → bin/states/llm/ (local only, never commit).
import
  std/[os, strformat, options],
  ../decompbound/[cpu, snesbus, save_state, png_state, policy],
  ../tools/[touch_grass, story_percents]

const
  OutDir = "bin/states/llm"
  Pics = "/home/monofuel/Pictures/Screenshots"

proc extractOne(name, outName: string) =
  let path = Pics / name
  if not fileExists(path):
    echo "SKIP missing ", path
    return
  let stOpt = extractState(cast[seq[uint8]](readFile(path)))
  if stOpt.isNone:
    echo "SKIP no ebSt ", name
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  deserializeState(stOpt.get, snes, c)
  let outPath = OutDir / outName
  writeFile(outPath, cast[string](serializeState(snes, c)))
  let i = PlayerSlot * SlotIndexStride
  echo fmt"WROTE {outPath} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) party={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X},{readU8(snes,0x988E):02X}"
  echo "  ", checkpointSpineLine(snes)

proc main() =
  createDir(OutDir)
  # Solo Poo (Dalaam-era candidate)
  extractOne("earthbound_20260719-224017.png", "poo_solo.state")
  # Full party first Poo join-ish
  extractOne("earthbound_20260719-230259.png", "poo_joined.state")
  # Deep south with Poo (fourside soft high)
  extractOne("earthbound_20260719-222020.png", "fourside_deep_prepoo.state")  # pre-poo high y
  extractOne("earthbound_20260719-231117.png", "poo_deep_south.state")
  extractOne("earthbound_20260723-225722.png", "poo_very_deep.state")
  extractOne("earthbound_20260724-000811.png", "poo_late_map.state")
  extractOne("earthbound_20260724-011033.png", "poo_indoor_late.state")

when isMainModule: main()
