## Load ebSt from a state-screenshot PNG and print key PPU state + re-render.
import
  std/[os, options, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, png_state, save_state]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len:
    result[i] = data[start + i].uint8

proc main() =
  ## Deserialize ebSt from PNG, dump PPU fade-relevant regs, re-render.
  if paramCount() < 2:
    echo "Usage: nim r src/tools/inspect_ebst.nim <rom> <screenshot.png> [out.png]"
    quit(1)
  let pngBytes = cast[seq[uint8]](readFile(paramStr(2)))
  let opt = extractState(pngBytes)
  if opt.isNone:
    echo "no ebSt in PNG"
    quit(1)
  let payload = opt.get
  echo "ebSt raw state bytes=", payload.len
  let rom = readRomFile(paramStr(1))
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  deserializeState(payload, snes, cpu)
  echo &"INIDISP={snes.ppuRegs[0x00]:02X} CGADSUB={snes.ppuRegs[0x31]:02X} CGWSEL={snes.ppuRegs[0x30]:02X}"
  echo &"TM={snes.ppuRegs[0x2C]:02X} TS={snes.ppuRegs[0x2D]:02X} BGMODE={snes.ppuRegs[0x05]:02X} HDMAEN={snes.hdmaen:02X}"
  echo &"BG1SC={snes.ppuRegs[0x07]:02X} BG2SC={snes.ppuRegs[0x08]:02X} BG12NBA={snes.ppuRegs[0x0B]:02X}"
  var nonzero = 0
  for i in 0 ..< 256:
    if snes.cgram[i] != 0: inc nonzero
  echo &"cgram nonzero entries={nonzero}/256"
  for pal in 0 ..< 16:
    var any = false
    var line = &"  pal{pal:02}:"
    for c in 0 ..< 16:
      let v = snes.cgram[pal * 16 + c]
      if v != 0: any = true
      line.add &" {v:04X}"
    if any: echo line
  # dump first 32 of WRAM $0200 palette buffer
  stdout.write "wram0200:"
  for i in 0 ..< 32:
    let v = snes.bus.mem[0x7E0200 + i]
    stdout.write &" {v:02X}"
  echo ""
  let img = ppu.renderFrame(snes)
  let outp = if paramCount() >= 3: paramStr(3) else: "bin/ebst_rerender.png"
  img.writeFile(outp)
  echo "wrote ", outp
  var yg = 0
  var lit = 0
  var red = 0
  for px in img.data:
    let s = px.r.int + px.g.int + px.b.int
    if s > 40: inc lit
    if px.r > 50 and px.r > px.g + 15 and px.r > px.b + 15: inc red
    if px.g > 40 and px.g + 10 >= px.r and px.g >= px.b: inc yg
  echo &"rerender lit={lit} redish={red} greenish={yg}"

when isMainModule:
  main()
