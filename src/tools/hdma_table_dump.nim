## Dump HDMA ch5 table + first indirect payloads at intro static.
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus]

const InstrPerLine = 150

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc r8(snes: SnesBus, a: uint32): uint8 = snes.bus.read8(a)

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  snes.initHdma()
  var line = 0
  var frameNum = 0
  var written: seq[(int, uint16)]  # line, bg2hofs after hdma
  while frameNum <= 1400 and not cpu.stopped:
    if line == 224 and (snes.nmitimen and 0x80) != 0: cpu.nmiPending = true
    for i in 0 ..< InstrPerLine: cpu.step(snes.bus)
    if line < 224:
      let before = snes.hdmaWrites.len
      snes.runHdma()
      if frameNum == 1400:
        # collect writes this line to $210F/$2110
        var wh = ""
        for i in before ..< snes.hdmaWrites.len:
          let (off, v) = snes.hdmaWrites[i]
          if off == 0x210F or off == 0x2110 or off == 0x210D or off == 0x210E:
            wh.add(&" ${off:04X}={v:02X}")
        if line < 12 or line mod 20 == 0:
          echo &"line={line:03d} BG2H={snes.bgScroll[2]:04X} BG2V={snes.bgScroll[3]:04X} writes:{wh}"
    for k in 0 ..< 2: discard snes.tickApu()
    line += 1
    if line >= 262:
      if frameNum == 1400:
        let ch = 5
        let b = ch * 0x10
        let dmap = snes.dmaRegs[b]
        let bbad = snes.dmaRegs[b+1]
        let bank = snes.dmaRegs[b+4].uint32
        let lo = snes.dmaRegs[b+2].uint32
        let hi = snes.dmaRegs[b+3].uint32
        let tbase = (bank shl 16) or lo or (hi shl 8)
        let ibank = snes.dmaRegs[b+7]
        echo &"ch5 dmap={dmap:02X} bbad={bbad:02X} tableBase={tbase:06X} dasb={ibank:02X}"
        var t = tbase
        for ent in 0 ..< 16:
          let count = r8(snes, t)
          if count == 0:
            echo &"  [{ent}] TERMINATOR at {t:06X}"
            break
          let lines = count and 0x7F
          let cont = (count and 0x80) != 0
          t += 1
          if (dmap and 0x40) != 0:
            let plo = r8(snes, t).uint32
            let phi = r8(snes, t+1).uint32
            t += 2
            let iptr = (ibank.uint32 shl 16) or plo or (phi shl 8)
            let v0 = r8(snes, iptr)
            let v1 = r8(snes, iptr+1)
            echo &"  [{ent}] count={count:02X} lines={lines} rep={cont} iptr={iptr:06X} data={v0:02X} {v1:02X}"
          else:
            echo &"  [{ent}] count={count:02X}"
        quit(0)
      line = 0
      frameNum += 1
      snes.hdmaWrites.setLen(0)
      snes.initHdma()

when isMainModule: main()
