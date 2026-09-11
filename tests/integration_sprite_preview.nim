import
  pixie,
  decompbound/[cpu, memmap, ppu, rom_pipeline, snesbus, sprite_preview]

const
  FrameResources = [0, 7, 15, 16, 27, 40, 41, 44, 49, 50, 145, 177,
    203, 204, 205, 206, 209, 252, 437]

proc word(gold: seq[uint8], offset: int): int =
  ## Read an original little-endian metadata word.
  gold[offset].int or (gold[offset + 1].int shl 8)

proc pointer(gold: seq[uint8], offset: int): int =
  ## Resolve a metadata table's original HiROM pointer.
  snesToFile(gold[offset].uint32 or (gold[offset + 1].uint32 shl 8) or
    (gold[offset + 2].uint32 shl 16))

proc checkPreview(gold: seq[uint8], resourceId, direction, phase: int) =
  ## Compare original layout composition with the emulator's final rendered pixels.
  let
    snes = buildSpritePreview(gold, resourceId, direction, phase)
    resource = gold.pointer(0x2F133F + resourceId * 4)
    layout = gold.pointer(0x042B0D + gold[resource + 2].int * 4)
    count = gold[layout].int
    entry = gold.word(resource + 9 + gold.word(0xA60B + direction * 2) * 4 + phase * 2)
    variant = entry and 1
    expected = newImage(256, 224)
  expected.fill(rgba(0, 0, 0, 255))
  doAssert snes.bus.read16(0x7E341A) == entry.uint16
  for record in countdown(count - 1, 0):
    let
      definition = layout + 2 + (variant * count + record) * 5
      tileWord = gold.word(0x04303C + record * 2)
      attribute = ((gold[definition + 2].int and 0xFE) or gold[resource + 3].int or
        (tileWord shr 8))
      x = 128 + cast[int8](gold[definition + 3]).int
      y = 112 + cast[int8](gold[definition]).int
      size = if (gold[definition + 4] and 1) == 0: 16 else: 32
      tile = tileWord and 255
      base = 0x4000 + (attribute and 1) * 0x1000
    doAssert snes.oam[record * 4] == x.uint8
    doAssert snes.oam[record * 4 + 1] == ((y - 1) and 255).uint8
    doAssert snes.oam[record * 4 + 2] == tile.uint8
    doAssert snes.oam[record * 4 + 3] == ((attribute and 0xCF) or 0x30).uint8
    for py in 0 ..< size:
      for px in 0 ..< size:
        let
          sx = if (attribute and 0x40) != 0: size - 1 - px else: px
          sy = if (attribute and 0x80) != 0: size - 1 - py else: py
          tileIndex = (((tile div 16 + sy div 8) mod 16) * 16) +
            ((tile mod 16 + sx div 8) mod 16)
          rowAddress = base + tileIndex * 16 + sy mod 8
          low = snes.vram[rowAddress].int
          high = snes.vram[rowAddress + 8].int
          bit = 7 - sx mod 8
          index = ((low shr bit) and 1) or (((low shr (bit + 8)) and 1) shl 1) or
            (((high shr bit) and 1) shl 2) or (((high shr (bit + 8)) and 1) shl 3)
        if index != 0 and x + px in 0 ..< 256 and y + py in 0 ..< 224:
          let
            paletteIndex = ((attribute shr 1) and 7) * 16 + index
            color = gold.word(0x030000 + paletteIndex * 2)
            red = color and 31
            green = (color shr 5) and 31
            blue = (color shr 10) and 31
          expected[x + px, y + py] = rgba((red * 8 + red div 4).uint8,
            (green * 8 + green div 4).uint8, (blue * 8 + blue div 4).uint8, 255)
  let actual = snes.renderFrame()
  doAssert actual.data == expected.data,
    "Sprite mismatch: " & $resourceId & "/" & $direction & "/" & $phase

proc main() =
  ## Check every resource and representative direction/phase combinations.
  let gold = readGoldBaserom()
  for resource in 0 ..< ResourceCount:
    gold.checkPreview(resource, 0, 0)
  for resource in FrameResources:
    for direction in 0 .. 7:
      for phase in 0 .. 1:
        if direction != 0 or phase != 0:
          gold.checkPreview(resource, direction, phase)

when isMainModule:
  main()
