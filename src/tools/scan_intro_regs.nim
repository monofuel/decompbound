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
  var line=0; var f=0
  var prev = ""
  let maxF = if paramCount()>=2: parseInt(paramStr(2)) else: 2500
  while f <= maxF and not cpu.stopped:
    snes.setScanline(line)
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
      snes.raiseNmi()
    for i in 0 ..< InstrPerLine: cpu.step(snes.bus)
    if line < 224: snes.runHdma()
    for k in 0 ..< 2: discard snes.tickApu()
    line += 1
    if line >= 262:
      line = 0
      let tm=snes.ppuRegs[0x2C]
      let s = &"INI={snes.ppuRegs[0x00]:02X} MODE={snes.ppuRegs[0x05] and 7} TM={tm:02X} TS={snes.ppuRegs[0x2D]:02X} CGAD={snes.ppuRegs[0x31]:02X}"
      let interesting = s != prev or (tm and 0x10) != 0 or f mod 100 == 0
      if interesting:
        echo &"f={f} {s}"
        prev = s
      f += 1
      snes.initHdma()
when isMainModule: main()
