import
  std/unittest,
  decompbound/world_map_assets

proc authoredGraphics(tiles: int): seq[uint8] =
  ## Encode a small arithmetic pattern independently of the row decoder.
  result = newSeq[uint8](tiles * 32)
  for tile in 0..<tiles:
    for y in 0..<8:
      for x in 0..<8:
        let index = (tile * 5 + y * 3 + x) and 15
        for plane in 0..<4:
          if (index and (1 shl plane)) != 0:
            let offset = tile * 32 + y * 2 + (plane div 2) * 16 + plane mod 2
            result[offset] = result[offset] or (1'u8 shl (7 - x))

suite "Shared map tile-row decoding":
  test "all planes and row positions agree with authored indices and the scalar decoder":
    let resource = WorldMapResource(graphics: authoredGraphics(3))
    for tile in 0..<3:
      for y in 0..<8:
        var row: array[8, uint8]
        decodePlanarTileRow(resource.graphics, tile, y, row)
        for x in 0..<8:
          check row[x] == ((tile * 5 + y * 3 + x) and 15).uint8
          check row[x] == resource.pixelIndex(tile, x, y)
  test "the final legal tile row works and invalid ranges fail before decoding":
    var
      graphics = newSeq[uint8](WorldChrBytes)
      row: array[8, uint8]
    decodePlanarTileRow(graphics, WorldChrTileCount - 1, 7, row)
    check row == default(array[8, uint8])
    for (tile, y) in [(-1, 0), (WorldChrTileCount, 0), (0, -1), (0, 8)]:
      expect ValueError:
        decodePlanarTileRow(graphics, tile, y, row)
    for size in [0, 17, 31]:
      graphics.setLen(size)
      expect ValueError:
        decodePlanarTileRow(graphics, 0, if size == 31: 7 else: 0, row)
