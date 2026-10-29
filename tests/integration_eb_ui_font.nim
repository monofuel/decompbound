import
  std/strutils,
  pixie,
  decompbound/[asm_parse, cpu, eb_ui_font, rom_pipeline, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  DirectPage = 0x0200
  StringAddress = 0x0400
  BlitBuffer = 0x3492
  StepLimit = 100000

proc putWord(machine: SnesBus, address, value: int) =
  ## Initialize one generated WRAM word for the original renderer.
  machine.bus.write8(Wram + address.uint32, uint8(value and 255))
  machine.bus.write8(Wram + address.uint32 + 1, uint8(value shr 8))

proc original(machine: SnesBus, target: uint32, a = 0, x = 0): uint16 =
  ## Invoke an original RTL routine without changing the ROM or live game.
  let code = assembleAsm(".a16\n.i16\nJSL $" & target.toHex(6) & "\n", Caller)
  for index, value in code:
    machine.bus.write8(Wram + Caller + index.uint32, value)
  var
    state = Cpu(pbr: 0x7E, pc: Caller.uint16, s: 0x1FFF, d: DirectPage,
      dbr: 0x7E, a: a.uint16, x: x.uint16)
    steps = 0
  while state.pbr != 0x7E or state.pc != (Caller + code.len.uint32).uint16:
    doAssert steps < StepLimit, "Original font routine did not return"
    state.step(machine.bus)
    inc steps
  state.a

proc checkFont(machine: SnesBus, rom: seq[uint8], font: EbUiFont) =
  ## Compare every glyph's width and painted pixels to original execution.
  let
    desc = FontDescriptorFile + font.fontId * FontDescriptorStride + FontBitmapPtrOff
    bitmapAddress = rom[desc].int or (rom[desc + 1].int shl 8) or (rom[desc + 2].int shl 16)
    white = ColorRGBA(r: 255, g: 255, b: 255, a: 255)
    black = ColorRGBA(a: 255)
    palette: array[4, ColorRGBA] = [black, white, black, black]
  for index in 0 ..< FontGlyphCount:
    let encoded = uint8(index + GlyphIndexBias)
    machine.bus.write8(Wram + StringAddress, encoded)
    machine.bus.write8(Wram + StringAddress + 1, 0)
    machine.putWord(DirectPage + 0x0E, StringAddress)
    machine.putWord(DirectPage + 0x10, 0x7E)
    machine.putWord(TrackingWram, 0)
    doAssert machine.original(StringWidthSnes, 1, font.fontId).int == font.glyphWidth(index)
    var tracked = font
    tracked.extraSpacing = 1
    machine.putWord(TrackingWram, 1)
    doAssert machine.original(StringWidthSnes, 1, font.fontId).int == tracked.glyphWidth(index)
    let rendered = newImage(font.cellWidth, font.height)
    rendered.fill(black)
    drawEbText(rendered, font, [encoded], 0, 0, palette)
    for column in 0 ..< (font.glyphWidth(index) + 7) div 8:
      let
        address = bitmapAddress + index * font.stride + column * font.height
        width = min(8, font.glyphWidth(index) - column * 8)
      machine.putWord(DirectPage + 0x0E, address and 0xFFFF)
      machine.putWord(DirectPage + 0x10, address shr 16)
      machine.putWord(0x9E23, 0)
      machine.putWord(0x9E25, 0)
      for offset in 0 ..< 64:
        machine.bus.write8(Wram + BlitBuffer + offset.uint32, 255)
      discard machine.original(GlyphBlitSnes, width, font.height)
      for y in 0 ..< font.height:
        let bits = machine.bus.read8(Wram + BlitBuffer + (y * 2 + 1).uint32)
        for x in 0 ..< width:
          let ink = (bits and (0x80'u8 shr x)) == 0
          doAssert font.glyphPixel(index, column * 8 + x, y) == ord(ink)
          doAssert rendered[column * 8 + x, y].r == (if ink: 255'u8 else: 0'u8)

proc main() =
  ## Validate all five ROM fonts against the game's width and bitmap blitters.
  let
    rom = readGoldBaserom()
    machine = newSnesBus(rom)
  for id in 0 ..< FontDescriptorCount:
    checkFont(machine, rom, loadEbUiFont(rom, id))

main()
