## Dump HDMA channel 5 + mid-scanline BG2 scroll during intro static.
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

proc main() =
  if paramCount() < 1:
    echo "Usage: nim r src/tools/hdma_static_probe.nim <rom>"
    quit(1)
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  snes.initHdma()
  var line = 0
  var frameNum = 0
  let targetFrame = 1400
  var samples: seq[string]
  while frameNum <= targetFrame and not cpu.stopped:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
    if line < 224:
      snes.runHdma()
      if frameNum == targetFrame and (line mod 16 == 0 or line < 8):
        let ch5base = 5 * 0x10
        samples.add(&"line={line:03d} BG2V={snes.bgScroll[3]:04X} BG2H={snes.bgScroll[2]:04X} BG1V={snes.bgScroll[1]:04X} BG1H={snes.bgScroll[0]:04X} HDMAEN={snes.hdmaen:02X} ch5dmap={snes.dmaRegs[ch5base]:02X} ch5bbad={snes.dmaRegs[ch5base+1]:02X} hdmaWrites={snes.hdmaWrites.len}")
    for k in 0 ..< 2: discard snes.tickApu()
    line += 1
    if line >= 262:
      if frameNum == targetFrame:
        echo "=== frame ", targetFrame, " mid-scanline samples ==="
        for s in samples: echo s
        echo "total hdma B-bus writes this frame window (cumulative)=", snes.hdmaWrites.len
        # dump last 40 hdma writes
        let n = snes.hdmaWrites.len
        let start = max(0, n - 40)
        echo "last HDMA writes (offset,value):"
        for i in start ..< n:
          let (off, v) = snes.hdmaWrites[i]
          echo &"  ${off:04X} <- {v:02X}"
        # channel table setup
        for ch in 0..7:
          if (snes.hdmaen and (1'u8 shl ch)) != 0:
            let b = ch * 0x10
            echo &"ch{ch}: dmap={snes.dmaRegs[b]:02X} bbad={snes.dmaRegs[b+1]:02X} a={snes.dmaRegs[b+4]:02X}:{snes.dmaRegs[b+3]:02X}{snes.dmaRegs[b+2]:02X}"
        quit(0)
      line = 0
      frameNum += 1
      snes.hdmaWrites.setLen(0)
      snes.initHdma()

when isMainModule: main()
