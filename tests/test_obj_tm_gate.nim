## Referee: renderSprites must honor the OBJ layer enable (TM $212C / TS $212D
## bit 4) as recorded per scanline by renderScanline. With OBJ off on both
## screens (the Giygas praying cutscene runs TM=$04 with sprites parked in
## OAM), hardware shows no sprites — the emulator must not draw them either.
## Legacy callers that never run renderScanline keep the old permissive
## behavior (sprites drawn), so probes and fixtures stay valid.

import
  std/[os, strformat],
  pixie,
  decompbound/[ppu, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  SpriteX = 10
  SpriteOamY = 49          ## Hardware draws the first row at OAM Y + 1 = 50.
  SpriteRowY = 50

proc readRom(p: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(p))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc setupSprite(snes: SnesBus) =
  ## Park all sprites offscreen, then place sprite 0 at (SpriteX, SpriteOamY)
  ## with tile 0 whose top row decodes to color index 1 (white via CGRAM 129).
  for sprite in 0 ..< 128:
    snes.oam[sprite * 4 + 1] = 240   ## Y=240 with size 8: pure offscreen park.
  snes.oam[0] = SpriteX.uint8
  snes.oam[1] = SpriteOamY.uint8
  snes.oam[2] = 0                    ## Tile 0.
  snes.oam[3] = 0                    ## Palette group 0, priority 0.
  snes.ppuRegs[0x01] = 0x00          ## OBSEL: chr base $0000, sizes 8/16.
  snes.ppuRegs[0x00] = 0x0F          ## INIDISP: full brightness, no blank.
  snes.vram[0] = 0x00FF              ## Tile 0 row 0, plane 0 = $FF -> index 1.
  snes.cgram[129] = 0x7FFF           ## OBJ palette 0 color 1 = white.

proc spritePixelLit(image: Image): bool =
  ## Whether the sprite's top-left pixel rendered bright.
  image[SpriteX, SpriteRowY].r > 200

proc renderFrame(snes: SnesBus, image: Image, runScanlines: bool) =
  ## One static frame render matching the play/rerender composition order.
  image.fill(ppu.bgr555ToColor(snes.cgram[0]))
  if runScanlines:
    for line in 0 ..< 224:
      ppu.renderScanline(snes, image, line)
  ppu.renderSprites(snes, image)

proc main() =
  ## Gate on, gate off, and legacy-caller phases.
  if not fileExists(RomPath):
    echo "[test_obj_tm_gate] SKIP (ROM absent)"
    return

  let snes = newSnesBus(readRom(RomPath))
  discard snes.resetCpu()
  setupSprite(snes)
  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)

  # --- Phase 1 (legacy callers): no renderScanline pass -> sprites drawn ---
  snes.ppuRegs[0x2C] = 0x04          ## TM: BG3 only, OBJ off.
  snes.ppuRegs[0x2D] = 0x00          ## TS: nothing.
  renderFrame(snes, image, runScanlines = false)
  doAssert spritePixelLit(image),
    "legacy path (no renderScanline) must still draw sprites"
  echo "[test_obj_tm_gate] legacy permissive ok"

  # --- Phase 2: OBJ disabled on both screens -> sprite hidden ---
  renderFrame(snes, image, runScanlines = true)
  doAssert not spritePixelLit(image),
    &"sprite drawn with OBJ off (TM=04 TS=00): pixel r={image[SpriteX, SpriteRowY].r}"
  echo "[test_obj_tm_gate] OBJ-off gate ok"

  # --- Phase 3: OBJ re-enabled on the main screen -> sprite drawn again ---
  snes.ppuRegs[0x2C] = 0x14          ## TM: BG3 + OBJ.
  renderFrame(snes, image, runScanlines = true)
  doAssert spritePixelLit(image),
    "sprite missing with OBJ enabled (TM=14)"
  echo "[test_obj_tm_gate] OBJ-on ok"

when isMainModule:
  main()
