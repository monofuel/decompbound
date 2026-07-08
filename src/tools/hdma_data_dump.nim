import std/[os, strformat, strutils], ../decompbound/[cpu, snesbus]
const InstrPerLine = 150
proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8
proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  snes.initHdma()
  var line=0; var frameNum=0
  while frameNum < 1400 and not cpu.stopped:
    if line == 224 and (snes.nmitimen and 0x80) != 0: cpu.nmiPending = true
    for i in 0 ..< InstrPerLine: cpu.step(snes.bus)
    if line < 224: snes.runHdma()
    for k in 0 ..< 2: discard snes.tickApu()
    line += 1
    if line >= 262:
      line=0; frameNum+=1; snes.initHdma()
  # dump WRAM at table region
  echo "7E3C32 table region (80 bytes):"
  for i in 0 ..< 80:
    let a = 0x7E3C32 + i
    let v = snes.bus.read8(a.uint32)
    if i mod 16 == 0: stdout.write &"{a:06X}: "
    stdout.write &"{v:02X} "
    if i mod 16 == 15: echo ""
  echo ""
  echo "7E3C46 data (256 bytes of supposed scroll):"
  var nonzero = 0
  for i in 0 ..< 256:
    let v = snes.bus.read8((0x7E3C46 + i).uint32)
    if v != 0: nonzero += 1
    if i mod 16 == 0: stdout.write &"{0x7E3C46+i:06X}: "
    stdout.write &"{v:02X} "
    if i mod 16 == 15: echo ""
  echo &"nonzero bytes in 256: {nonzero}"
  # Also sample BG2 tilemap / char base registers
  echo &"BG1SC={snes.ppuRegs[0x07]:02X} BG2SC={snes.ppuRegs[0x08]:02X}"
  echo &"BG12NBA={snes.ppuRegs[0x0B]:02X} BG34NBA={snes.ppuRegs[0x0C]:02X}"
  echo &"TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} CGADSUB={snes.ppuRegs[0x31]:02X}"
when isMainModule: main()
