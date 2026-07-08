import
  std/[os, strformat, options, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, png_state]

proc readRom(p: string): seq[uint8] =
  let d = readFile(p)
  var s = 0
  if d.len mod 1024 == 512: s = 512
  result = newSeq[uint8](d.len - s)
  for i in 0..<result.len: result[i] = d[s+i].uint8

proc main() =
  let path = paramStr(1)
  let snes = newSnesBus(readRom("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  let raw = if path.endsWith(".png"): extractState(cast[seq[uint8]](readFile(path))).get
            else: cast[seq[uint8]](readFile(path))
  deserializeState(raw, snes, cpu)
  let mode = snes.ppuRegs[0x05] and 7
  echo fmt"mode={mode} MODE_reg={snes.ppuRegs[0x05]:02X} TM={snes.ppuRegs[0x2C]:02X}"
  # Count tilemap priority bits for BG1 and BG3
  for bg in 0..2:
    let sc = snes.ppuRegs[0x07 + bg]
    let tilemapBase = ((sc.int shr 2) shl 10) and 0x7FFF
    var hi, lo, nz = 0
    for i in 0 ..< 32*32:
      let e = snes.vram[(tilemapBase + i) and 0x7FFF]
      let tile = e and 0x3FF
      if tile == 0: continue
      inc nz
      if (e and 0x2000) != 0: inc hi else: inc lo
    echo fmt"BG{bg+1} mapBase={tilemapBase:04X} nonzero={nz} prio_hi={hi} prio_lo={lo}"

  # Composite WITHOUT priority split (all tiles) vs WITH modeLayers path
  # Per-scanline composite is renderScanline - already uses modeLayers.
  # Compare: if we draw BG3 after BG1, UI buried.
  let full = newImage(256, 224)
  full.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0..<224: ppu.renderScanline(snes, full, line)
  ppu.renderSprites(snes, full)
  full.writeFile("bin/battle_ui_scanline.png")

  # Wrong order test: BG1 then BG3 on top
  let wrong = newImage(256, 224)
  wrong.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0..<224:
    ppu.renderBgScanline(snes, wrong, line, 0, 2, 0, -1)
    ppu.renderBgScanline(snes, wrong, line, 2, 2, 64, -1)
  wrong.writeFile("bin/battle_ui_wrong_order.png")

  # Right order: BG3 then BG1
  let right = newImage(256, 224)
  right.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0..<224:
    ppu.renderBgScanline(snes, right, line, 2, 2, 64, -1)
    ppu.renderBgScanline(snes, right, line, 0, 2, 0, -1)
  right.writeFile("bin/battle_ui_right_order.png")

  # BG1 hi only after BG3 all
  let split = newImage(256, 224)
  split.fill(ppu.bgr555ToColor(snes.cgram[0]))
  for line in 0..<224:
    ppu.renderBgScanline(snes, split, line, 2, 2, 64, -1)
    ppu.renderBgScanline(snes, split, line, 0, 2, 0, 0)
    ppu.renderBgScanline(snes, split, line, 0, 2, 0, 1)
  split.writeFile("bin/battle_ui_split.png")

when isMainModule: main()
