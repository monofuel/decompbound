## Extract the ebSt save-state embedded in an F12 screenshot PNG and write it to
## a state slot, so state_inspect / play can load and render it. Turns a user
## bug-report screenshot into a loadable, renderable machine state.
##
## Usage: nim r src/tools/png_to_slot.nim <rom> <screenshot.png> <slot>

import
  std/[os, options, strutils],
  ../decompbound/[save_state, snesbus, cpu, png_state]

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

when isMainModule:
  if paramCount() < 3:
    echo "Usage: nim r src/tools/png_to_slot.nim <rom> <screenshot.png> <slot>"
    quit(1)
  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  var cpuInst = snes.resetCpu()
  let pngBytes = cast[seq[uint8]](readFile(paramStr(2)))
  let stOpt = extractState(pngBytes)
  if stOpt.isNone:
    echo "no ebSt state embedded in ", paramStr(2)
    quit(1)
  deserializeState(cast[seq[byte]](stOpt.get), snes, cpuInst)
  let slot = parseInt(paramStr(3))
  saveState(snes, cpuInst, slot)
  echo "extracted ", paramStr(2), " -> slot ", slot
