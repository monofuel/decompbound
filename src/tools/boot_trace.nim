## Boots a ROM on the emulator core and traces execution.
## Milestone 2 probe: how far does the real Earthbound boot get on the
## CPU core + SNES bus? Prints the first N instructions, then run
## statistics: where execution settled, MMIO traffic, unique PCs.
## Usage: nim r src/tools/boot_trace.nim <rom> [instructions] [trace-count]

import
  std/[os, sets, strformat, strutils, tables],
  ../decompbound/[assembler, cpu, opcodes, snesbus]

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
  if paramCount() < 1:
    echo "Usage: nim r src/tools/boot_trace.nim <rom> [instructions] [trace-count]"
    quit(1)

  var maxInstructions = 1_000_000
  var traceCount = 40
  if paramCount() >= 2:
    maxInstructions = parseInt(paramStr(2))
  if paramCount() >= 3:
    traceCount = parseInt(paramStr(3))

  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()

  echo &"Reset vector: ${cpu.pc:04X}"
  echo ""

  var executed = 0
  var pcHistogram = initCountTable[uint32]()
  var uniquePcs = initHashSet[uint32]()

  while executed < maxInstructions and not cpu.stopped:
    let fullPc = (cpu.pbr.uint32 shl 16) or cpu.pc.uint32
    if executed < traceCount:
      let flags = FlagState(m8: cpu.m8, x8: cpu.x8, emulation: cpu.emulation)
      var window: array[4, uint8]
      for i in 0..3:
        window[i] = snes.bus.read8(fullPc + i.uint32)
      let instr = decode(window, 0, flags)
      echo &"${fullPc:06X}  {formatInstruction(instr)}"
    if cpu.waiting:
      # WAI: no interrupts wired yet; treat as settled.
      echo &"(settled: WAI at ${fullPc:06X} after {executed} instructions)"
      break
    pcHistogram.inc fullPc
    uniquePcs.incl fullPc
    cpu.step(snes.bus)
    executed += 1

  echo ""
  echo &"Executed {executed} instructions, {uniquePcs.len} unique PCs."
  echo &"MMIO: {snes.mmioWrites.len} writes, {snes.mmioReads.len} reads."

  pcHistogram.sort()
  echo "Hottest PCs (the loop it settled into):"
  var shown = 0
  for pc, count in pcHistogram:
    echo &"  ${pc:06X}: {count} times"
    shown += 1
    if shown >= 8:
      break

  var writeCounts = initCountTable[uint32]()
  for (address, _) in snes.mmioWrites:
    writeCounts.inc address
  writeCounts.sort()
  echo "Top MMIO writes:"
  shown = 0
  for address, count in writeCounts:
    echo &"  ${address:04X}: {count} writes"
    shown += 1
    if shown >= 10:
      break

when isMainModule:
  main()
