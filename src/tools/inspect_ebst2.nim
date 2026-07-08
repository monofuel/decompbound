## Deeper dump of Giygas palette-anim WRAM from an ebSt screenshot.
import
  std/[os, options, strformat],
  ../decompbound/[cpu, snesbus, png_state, save_state]

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc w16(snes: SnesBus, a: int): uint16 =
  snes.bus.mem[a].uint16 or (snes.bus.mem[a+1].uint16 shl 8)

proc main() =
  let pngBytes = cast[seq[uint8]](readFile(paramStr(2)))
  let payload = extractState(pngBytes).get
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(payload, snes, cpu)
  echo &"INIDISP={snes.ppuRegs[0x00]:02X} CGAD={snes.ppuRegs[0x31]:02X}"
  # Palette anim: vel R 7F0200, G 7F0400, B 7F0600; pos R 7F0800 G 7F0A00 B 7F0C00
  # First 16 entries of each
  for (name, base) in [("velR", 0x7F0200), ("velG", 0x7F0400), ("velB", 0x7F0600),
                       ("posR", 0x7F0800), ("posG", 0x7F0A00), ("posB", 0x7F0C00)]:
    stdout.write name, ":"
    for i in 0 ..< 16:
      let v = w16(snes, base + i*2)
      let hi = (v shr 8) and 0x1F
      stdout.write &" {v:04X}({hi})"
    echo ""
  # count how many CGRAM are 6318
  var n6318 = 0
  var n0 = 0
  for i in 0 ..< 256:
    if snes.cgram[i] == 0x6318: inc n6318
    if snes.cgram[i] == 0: inc n0
  echo &"cgram 6318 count={n6318} zero={n0}"
  # decode a few 6318
  let v = 0x6318'u16
  echo &"6318 = R={(v and 0x1F)} G={((v shr 5) and 0x1F)} B={((v shr 10) and 0x1F)}"
  # DP related
  echo &"dp $0D (brightness shadow?)={snes.bus.mem[0x7E000D]:02X}"
  echo &"wram $30 (pal DMA)={snes.bus.mem[0x7E0030]:02X}"

when isMainModule: main()

# (appended nothing)
