import std/[os, options, strformat], ../decompbound/[cpu, snesbus, png_state, save_state]
proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8
proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  echo &"fixed RGB={snes.fixedColorR:02X},{snes.fixedColorG:02X},{snes.fixedColorB:02X}"
  echo &"cgram0={snes.cgram[0]:04X}"
  echo &"CGWSEL={snes.ppuRegs[0x30]:02X} CGADSUB={snes.ppuRegs[0x31]:02X}"
when isMainModule: main()
