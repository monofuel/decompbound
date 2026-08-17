## Dump sector + text quality from session F12s (report fidelity).

import
  std/[algorithm, options, os, strformat, strutils],
  ../decompbound/[cpu, png_state, policy, save_state, snesbus],
  ../tools/touch_grass

const
  RomPath = "bin/Earthbound (U) [!].smc"
  F12Dir = "../decompbound_secret/sessions/20260816-183136/f12"

proc readRom(path: string): seq[uint8] =
  ## ROM bytes minus copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc main() =
  ## One line per F12: pos, sector, tg, battle, dialogue/screen/battle lens.
  let rom = readRom(RomPath)
  var paths: seq[string] = @[]
  for kind, p in walkDir(F12Dir):
    if kind == pcFile and p.endsWith(".png"):
      paths.add p
  paths.sort()
  for p in paths:
    let png = cast[seq[uint8]](readFile(p))
    let st = extractState(png)
    if st.isNone:
      echo p.extractFilename, " NO-EBST"
      continue
    let snes = newSnesBus(rom)
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](st.get), snes, c)
    let idx = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + idx)
    let py = readU16(snes, WorldYBase + idx)
    let sec = readU16(snes, SectorOff)
    let dlg = getDialogueText(snes)
    let scr = getScreenText(snes)
    discard getBattleText(snes)
    let w0 = snes.bus.mem[0x7E8650]
    let w1 = snes.bus.mem[0x7E8654]
    let sl = snes.bus.mem[0x7E96C5]
    let sm = snes.bus.mem[0x7E96C6]
    let sb = snes.bus.mem[0x7E96C7]
    echo &"{p.extractFilename} pos=({px:04X},{py:04X}) w0={w0:02X} w1={w1:02X} " &
      &"stream={sb:02X}{sm:02X}{sl:02X} dlg={dlg.len} scr={scr.len}"
    if dlg.len > 0:
      echo "  DLG: ", dlg.replace("\n", " / ")[0 ..< min(100, dlg.len)]
    if scr.len > 40:
      let one = scr.replace("\n", " | ")
      echo "  SCR: ", one[0 ..< min(140, one.len)]

main()
