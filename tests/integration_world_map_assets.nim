import
  std/[sets, strformat, strutils],
  decompbound/[asm_parse, cpu, gfx_lz, rom_pipeline, snesbus, world_map_assets]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  StackTop = 0x1FFF'u16
  Output = 0x4000
  StepLimit = 5_000_000
  ArrangementReaderFile = 0x00035B
  ArrangementReaderSize = 54

proc put16(machine: SnesBus, offset, value: int) =
  ## Install one generated WRAM input word.
  machine.bus.write8(Wram + offset.uint32, uint8(value and 255))
  machine.bus.write8(Wram + offset.uint32 + 1, uint8((value shr 8) and 255))

proc get16(machine: SnesBus, offset: int): int =
  ## Read one original WRAM result independently of native resource structures.
  machine.bus.read8(Wram + offset.uint32).int or
    (machine.bus.read8(Wram + offset.uint32 + 1).int shl 8)

proc resourceSource(machine: SnesBus, state: Cpu): int =
  ## Read the decompressor's far pointer from the original loader's current frame.
  let source = machine.get16(state.d.int + 0x0E) or
    (machine.get16(state.d.int + 0x10) shl 16)
  source and 0x3FFFFF

proc verifyResourceSelectors(machine: SnesBus, assets: WorldMapAssets) =
  ## Execute the original resource loader through both decompressor call sites.
  var verified: HashSet[int]
  for region in 0 ..< 2560:
    let logical = machine.bus.read8(0xD7A800'u32 + region.uint32).int shr 3
    if logical in verified: continue
    verified.incl(logical)
    machine.put16(0x438A, 0)
    machine.put16(0x438C, 0)
    machine.put16(0x436E, 0xFFFF)
    var
      state = Cpu(pbr: 0xC0, pc: 0x08C3, s: StackTop, d: 0x1A00,
        dbr: 0x7E, a: (region mod 32).uint16, x: (region div 32).uint16)
      steps = 0
    while state.pbr != 0xC0 or state.pc != 0x0949:
      doAssert steps < StepLimit
      state.step(machine.bus)
      inc steps
    let
      draw = assets.drawingTileset(logical)
      resource = assets.resource(draw)
    doAssert machine.get16(state.d.int + 0x16) == draw,
      &"Original selector logical={logical} draw={draw} actual={machine.get16(state.d.int+0x16)} DP={state.d:04X}."
    doAssert machine.resourceSource(state) == resource.arrangementsFile
    while state.pbr != 0xC0 or state.pc != 0x09AD:
      doAssert steps < StepLimit
      state.step(machine.bus)
      inc steps
    doAssert machine.resourceSource(state) == resource.graphicsFile
  # Original table slot 31 is unused by the complete 2,560-sector atlas.
  doAssert verified.len == WorldLogicalTilesetCount - 1
  for logical in 0 ..< WorldLogicalTilesetCount - 1:
    doAssert logical in verified

proc call(machine: SnesBus, target: uint32, a = 0'u16, x = 0'u16,
    y = 0'u16, directPage = 0'u16): Cpu =
  ## Execute the original RTL routine through an authored isolated caller.
  let code = assembleAsm(".a16\n.i16\nJSL $" & target.toHex(6) & "\n", Caller)
  for index, value in code:
    machine.bus.write8(Wram + Caller + index.uint32, value)
  var
    state = Cpu(pbr: 0x7E, pc: Caller.uint16, s: StackTop, d: directPage,
      dbr: 0x7E, a: a, x: x, y: y)
    steps = 0
  while state.pbr != 0x7E or state.pc != (Caller + code.len.uint32).uint16:
    doAssert steps < StepLimit, &"Original ${target:06X} stalled at {state.pbr:02X}:{state.pc:04X}."
    state.step(machine.bus)
    inc steps
  doAssert state.s == StackTop
  state

proc verifyDecompress(machine: SnesBus, rom: seq[uint8], source: int,
    destination = Output) =
  ## Compare every decoded byte and extent with the original decompressor.
  let decoded = decodeWithConsumed(rom.toOpenArray(source, rom.high))
  doAssert decoded.clean
  machine.put16(0x0E, source and 0xFFFF)
  machine.put16(0x10, (source shr 16) or 0xC0)
  machine.put16(0x12, destination)
  machine.put16(0x14, 0x7F)
  for i in 0 .. decoded.data.len:
    machine.bus.write8(0x7F0000'u32 + destination.uint32 + i.uint32, 0xA5)
  discard machine.call(0xC41A9E)
  for i, value in decoded.data:
    doAssert machine.bus.read8(0x7F0000'u32 + destination.uint32 + i.uint32) == value,
      &"Original decompressor mismatch source={source:06X} offset={i:X}."
  doAssert machine.bus.read8(0x7F0000'u32 + destination.uint32 + decoded.data.len.uint32) == 0xA5

proc main() =
  ## Verify every drawing resource and every sector-referenced palette selector.
  let
    rom = readGoldBaserom()
    annotated = assembleAsm(readFile("asm/readWorldMapArrangementTile.asm"),
      ArrangementReaderFile.uint32)
    assets = newWorldMapAssets(rom)
    machine = newSnesBus(rom)
  doAssert annotated.len == ArrangementReaderSize
  doAssert annotated == rom[ArrangementReaderFile ..< ArrangementReaderFile + ArrangementReaderSize]
  defer:
    machine.bus.readHook = nil
    machine.bus.writeHook = nil
    machine.apu.spc.readHook = nil
    machine.apu.spc.writeHook = nil
  machine.verifyResourceSelectors(assets)
  for drawing in 0 ..< WorldDrawingTilesetCount:
    let resource = assets.resource(drawing)
    machine.verifyDecompress(rom, resource.graphicsFile)
    machine.verifyDecompress(rom, resource.arrangementsFile, 0x8000)
    discard machine.call(0xC006F2, a = drawing.uint16, directPage = 0x1A00)
    for arrangement in 0 ..< resource.arrangements.len:
      for y in 0 ..< 4:
        for x in 0 ..< 4:
          let actual = machine.call(0xC0035B, a = arrangement.uint16,
            x = x.uint16, y = y.uint16, directPage = 0x1A00)
          doAssert actual.a == resource.arrangements[arrangement][y * 4 + x],
            &"Arrangement draw={drawing} id={arrangement} x={x} y={y}; got{actual.a:04X}."
          doAssert actual.x == x.uint16 and actual.y == y.uint16
          doAssert actual.d == 0x1A00 and actual.dbr == 0x7E
          let word = actual.a.int
          if ((word shr 10) and 7) < 2:
            for py in 0 ..< 8:
              for px in 0 ..< 8:
                doAssert resource.pixelIndex(word and 0x3FF, px, py) == 0
                if (word and 0x3FF) < WorldBg2TileCount:
                  doAssert resource.pixelIndex((word and 0x3FF) + WorldBg2ChrTileOffset, px, py) == 0
    for offset in WorldBg2ChrTileOffset * 32 ..< (WorldBg2ChrTileOffset + 1) * 32:
      doAssert resource.graphics[offset] == 0, "Original empty BG2 tile is not blank."
  var palettes: HashSet[(int, int)]
  for offset in 0x17A800 ..< 0x17A800 + 2560:
    let
      logical = (rom[offset] shr 3).int
      index = (rom[offset] and 7).int
      key = (logical, index)
    if key in palettes: continue
    palettes.incl(key)
    let palette = assets.palette(logical, index)
    discard machine.call(0xC007B6, a = logical.uint16, x = index.uint16,
      directPage = 0x1A00)
    for color in 0 ..< 96:
      let
        address = Wram + 0x0240 + (color * 2).uint32
        actual = machine.bus.read8(address).uint16 or
          (machine.bus.read8(address + 1).uint16 shl 8)
      doAssert actual == palette.colors[32 + color],
        &"Palette logical={logical} index={index} color={color}; got{actual:04X}, want{palette.colors[32+color]:04X}."
  echo "Original decompressor matched all 20 CHR and 20 arrangement streams."
  echo "Original C0035B matched every arrangement's 16 tile words; BG2 tile zero is blank in all 20 sets."
  echo "Original palette loader matched all ", palettes.len, " referenced selectors with zero event flags."

main()
