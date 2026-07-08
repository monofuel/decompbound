## Verify logo 1px gap is gone after sprite Y+1 fix.
import
  std/[os, options, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, png_state, save_state]

proc readRomFile(filepath: string): seq[uint8] =
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512: start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0 ..< result.len: result[i] = data[start + i].uint8

proc dist(p, bd: ColorRGBA): int =
  abs(p.r.int - bd.r.int) + abs(p.g.int - bd.g.int) + abs(p.b.int - bd.b.int)

proc main() =
  let snes = newSnesBus(readRomFile(paramStr(1)))
  var cpu = snes.resetCpu()
  deserializeState(extractState(cast[seq[uint8]](readFile(paramStr(2)))).get, snes, cpu)
  let bd = ppu.bgr555ToColor(snes.cgram[0])
  let full = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  full.fill(bd)
  for line in 0 ..< 224:
    ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)
  full.writeFile("bin/logo_1px_fixed.png")

  var sandwiches = 0
  for x in 15 .. 240:
    for y in 100 .. 145:
      let a = dist(full[x, y], bd)
      let b = dist(full[x, y + 1], bd)
      let c = dist(full[x, y + 2], bd)
      if a > 80 and b < 35 and c > 50:
        inc sandwiches
  echo &"sandwich lit|backdrop|lit count={sandwiches}"

  # Sample column bottoms
  for x in [30, 90, 150, 210]:
    echo &"x={x}:"
    for y in 115 .. 122:
      let f = full[x, y]
      echo &"  y={y}: ({f.r},{f.g},{f.b}) d={dist(f, bd)}"

when isMainModule: main()
