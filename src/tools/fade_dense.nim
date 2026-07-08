import std/[os, strformat], pixie, ../decompbound/[cpu, ppu, snesbus]
const InstrPerLine = 150
proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8
proc cgramH(snes: SnesBus): uint32 =
  var h = 2166136261'u32
  for i in 0 ..< 256:
    let w = snes.cgram[i]
    h = (h xor (w and 0xFF).uint32) * 16777619'u32
    h = (h xor ((w shr 8) and 0xFF).uint32) * 16777619'u32
  h
proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  snes.initHdma()
  var line=0; var f=0
  createDir("bin/fade_trans")
  while f <= 1750 and not cpu.stopped:
    if line == 224 and (snes.nmitimen and 0x80) != 0: cpu.nmiPending = true
    for i in 0 ..< InstrPerLine: cpu.step(snes.bus)
    if line < 224: snes.runHdma()
    for k in 0 ..< 2: discard snes.tickApu()
    line += 1
    if line >= 262:
      line = 0
      if f >= 1580 and f <= 1720:
        let ini=snes.ppuRegs[0x00]; let cg=snes.ppuRegs[0x31]
        let tm=snes.ppuRegs[0x2C]; let ts=snes.ppuRegs[0x2D]
        let cw=snes.ppuRegs[0x30]; let mode=snes.ppuRegs[0x05]
        let bg1sc=snes.ppuRegs[0x07]; let bg2sc=snes.ppuRegs[0x08]
        let nba=snes.ppuRegs[0x0B]
        echo &"f={f} INI={ini:02X} MODE={mode:02X} CGAD={cg:02X} CW={cw:02X} TM={tm:02X} TS={ts:02X} HDMA={snes.hdmaen:02X} BG1SC={bg1sc:02X} BG2SC={bg2sc:02X} NBA={nba:02X} cgram={cgramH(snes):08X} BG1V={snes.bgScroll[1]:04X} BG2H={snes.bgScroll[2]:04X}"
        if f mod 5 == 0 or (f >= 1598 and f <= 1615):
          let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
          img.fill(ppu.bgr555ToColor(snes.cgram[0]))
          # re-render is wrong without mid-frame hdma - skip full re-render
      f += 1
      snes.initHdma()
when isMainModule: main()
