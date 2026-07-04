## Boots a ROM on the emulator and renders the PPU state to a PNG.
## Milestone 4 probe: what does Earthbound actually show?
## Usage: nim r src/tools/screenshot.nim <rom> <out.png> [instructions]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc main() =
  if paramCount() < 2:
    echo "Usage: nim r src/tools/screenshot.nim <rom> <out.png> [instructions]"
    quit(1)

  var maxInstructions = 2_000_000
  if paramCount() >= 3:
    maxInstructions = parseInt(paramStr(3))

  const InstructionsPerFrame = 8000
  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  for executed in 0..<maxInstructions:
    if (snes.nmitimen and 0x80) != 0 and
       executed mod InstructionsPerFrame == 0 and executed > 0:
      cpu.nmiPending = true
    cpu.step(snes.bus)
    if cpu.stopped:
      break

  let image = snes.renderFrame()
  image.writeFile(paramStr(2))
  echo &"Screenshot written to {paramStr(2)}"
  echo &"BGMODE={snes.ppuRegs[0x05] and 7} TM={snes.ppuRegs[0x2C]:02X} INIDISP={snes.ppuRegs[0x00]:02X}"

when isMainModule:
  main()
