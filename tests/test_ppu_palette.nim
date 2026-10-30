import
  std/unittest,
  pixie,
  decompbound/[ppu, save_state, snesbus]

const
  SyntheticRomBytes = 0x10000
  CharacterBase = 0x1000
  SecondCharacterBase = 0x2000
  SecondMapBase = 0x400
  DisplayRegister = 0x00
  ModeRegister = 0x05
  Bg2MapRegister = 0x08
  CharacterBasesRegister = 0x0B
  Bg12WindowRegister = 0x23
  WindowLeftRegister = 0x26
  WindowRightRegister = 0x27
  MainLayersRegister = 0x2C
  SubLayersRegister = 0x2D
  MainWindowRegister = 0x2E
  SubWindowRegister = 0x2F
  MathControlRegister = 0x30
  MathLayersRegister = 0x31
  FullBrightness = 0x0F'u8
  NmiEnable = 0x80'u8
  MainBg1 = 1'u8
  Bg2 = 2'u8
  SubscreenOperand = 2'u8
  Bg1WindowOne = 0x02'u8
  Bg2WindowOne = 0x20'u8
  Red = 0x001F'u16
  Green = 0x03E0'u16
  Blue = 0x7C00'u16
  White = 0x7FFF'u16
  PaletteShift = 10
  HighPriority = 0x2000'u16
  FlipHorizontal = 0x4000'u16
  FlipVertical = 0x8000'u16

proc machine(): SnesBus =
  ## Make authored blank hardware with BG1 enabled and a separate character area.
  result = newSnesBus(newSeq[uint8](SyntheticRomBytes))
  result.ppuRegs[DisplayRegister] = FullBrightness
  result.ppuRegs[MainLayersRegister] = MainBg1
  result.ppuRegs[CharacterBasesRegister] =
    uint8((CharacterBase shr 12) or ((SecondCharacterBase shr 12) shl 4))
  result.ppuRegs[Bg2MapRegister] = uint8(SecondMapBase shr 8)

proc release(snes: SnesBus) =
  ## Break the synthetic machine's bus and APU closure cycles.
  snes.bus.readHook = nil
  snes.bus.writeHook = nil
  snes.apu.spc.readHook = nil
  snes.apu.spc.writeHook = nil

proc solidTile(snes: SnesBus, base, bpp: int) =
  ## Set every bitplane of tile zero so each pixel uses the highest index.
  for pair in 0 ..< bpp div 2:
    for row in 0 ..< 8:
      snes.vram[base + pair * 8 + row] = 0xFFFF

proc expect(image: Image, x, y: int, value: uint16) =
  ## Compare a rendered pixel against independently specified SNES color channels.
  let pixel = image[x, y]
  check pixel.r == uint8(((value and 31) shl 3) or ((value and 31) shr 2))
  check pixel.g == uint8((((value shr 5) and 31) shl 3) or (((value shr 5) and 31) shr 2))
  check pixel.b == uint8((((value shr 10) and 31) shl 3) or (((value shr 10) and 31) shr 2))
  check pixel.a == 255

suite "Live background palette access":
  test "CGRAM changes become visible on the next scanline":
    let snes = machine()
    defer: release(snes)
    let image = newImage(ScreenWidth, ScreenHeight)
    snes.solidTile(CharacterBase, 2)
    snes.cgram[3] = Red
    snes.renderScanline(image, 0)
    snes.cgram[3] = Green
    snes.renderScanline(image, 1)
    image.expect(0, 0, Red)
    image.expect(255, 1, Green)

  test "alternating machines refresh the current thread's palette":
    let first = machine()
    let second = machine()
    defer: release(first)
    defer: release(second)
    let image = newImage(ScreenWidth, ScreenHeight)
    first.solidTile(CharacterBase, 2)
    second.solidTile(CharacterBase, 2)
    first.cgram[3] = Red
    second.cgram[3] = Blue
    for iteration in 0 ..< 4:
      first.renderScanline(image, 0)
      image.expect(42, 0, Red)
      second.renderScanline(image, 0)
      image.expect(42, 0, Blue)

  test "2bpp, 4bpp and 8bpp palette boundaries retain index masking":
    for setting in [(mode: 0, bpp: 2, index: 31),
        (mode: 1, bpp: 4, index: 127), (mode: 3, bpp: 8, index: 255)]:
      let snes = machine()
      defer: release(snes)
      let image = newImage(ScreenWidth, ScreenHeight)
      snes.ppuRegs[ModeRegister] = setting.mode.uint8
      snes.vram[0] = uint16(7 shl PaletteShift)
      snes.solidTile(CharacterBase, setting.bpp)
      snes.cgram[setting.index] = White
      snes.renderScanline(image, 0)
      image.expect(0, 0, White)
      image.expect(7, 0, White)

  test "transparent pixels and horizontal and vertical flips keep their positions":
    let snes = machine()
    defer: release(snes)
    let image = newImage(ScreenWidth, ScreenHeight)
    snes.cgram[0] = Blue
    snes.cgram[1] = Red
    snes.vram[CharacterBase] = 0x0080
    snes.vram[CharacterBase + 7] = 0x0001
    snes.vram[1] = FlipHorizontal
    snes.vram[2] = FlipVertical
    snes.vram[3] = FlipHorizontal or FlipVertical
    snes.renderScanline(image, 0)
    for x in [0, 15, 23, 24]: image.expect(x, 0, Red)
    for x in [1, 7, 8, 16, 22, 25, 31]: image.expect(x, 0, Blue)

  test "tile priority and live main-screen window select the right layer":
    let snes = machine()
    defer: release(snes)
    let image = newImage(ScreenWidth, ScreenHeight)
    snes.ppuRegs[MainLayersRegister] = MainBg1 or Bg2
    snes.solidTile(CharacterBase, 2)
    snes.solidTile(SecondCharacterBase, 2)
    snes.cgram[3] = Red
    snes.cgram[35] = Blue
    snes.vram[SecondMapBase] = HighPriority
    snes.renderScanline(image, 0)
    image.expect(0, 0, Blue)
    snes.vram[0] = HighPriority
    snes.renderScanline(image, 0)
    image.expect(0, 0, Red)
    snes.ppuRegs[Bg12WindowRegister] = Bg1WindowOne
    snes.ppuRegs[WindowLeftRegister] = 0
    snes.ppuRegs[WindowRightRegister] = 3
    snes.ppuRegs[MainWindowRegister] = MainBg1
    snes.renderScanline(image, 1)
    image.expect(0, 1, Blue)
    image.expect(4, 1, Red)

  test "subscreen palette and window remain independent of the main screen":
    let snes = machine()
    defer: release(snes)
    let image = newImage(ScreenWidth, ScreenHeight)
    snes.solidTile(CharacterBase, 2)
    snes.solidTile(SecondCharacterBase, 2)
    snes.cgram[3] = Red
    snes.cgram[35] = Blue
    snes.ppuRegs[SubLayersRegister] = Bg2
    snes.ppuRegs[MathControlRegister] = SubscreenOperand
    snes.ppuRegs[MathLayersRegister] = MainBg1
    snes.renderScanline(image, 0)
    image.expect(0, 0, Red or Blue)
    snes.ppuRegs[Bg12WindowRegister] = Bg2WindowOne
    snes.ppuRegs[WindowLeftRegister] = 0
    snes.ppuRegs[WindowRightRegister] = 3
    snes.ppuRegs[SubWindowRegister] = Bg2
    snes.renderScanline(image, 1)
    image.expect(0, 1, Red)
    image.expect(4, 1, Red or Blue)

  test "reset and state import do not retain palette contents":
    let snes = machine()
    defer: release(snes)
    let image = newImage(ScreenWidth, ScreenHeight)
    snes.solidTile(CharacterBase, 2)
    snes.cgram[3] = Red
    var cpuState = snes.resetCpu()
    snes.nmitimen = NmiEnable
    let original = serializeState(snes, cpuState)
    snes.renderScanline(image, 0)
    image.expect(0, 0, Red)
    snes.apu.spc.readHook = nil
    snes.apu.spc.writeHook = nil
    discard snes.softReset()
    snes.ppuRegs[DisplayRegister] = FullBrightness
    snes.ppuRegs[MainLayersRegister] = MainBg1
    snes.ppuRegs[CharacterBasesRegister] =
      uint8((CharacterBase shr 12) or ((SecondCharacterBase shr 12) shl 4))
    snes.solidTile(CharacterBase, 2)
    snes.cgram[3] = Green
    snes.renderScanline(image, 0)
    image.expect(0, 0, Green)
    deserializeState(original, snes, cpuState)
    snes.renderScanline(image, 0)
    image.expect(0, 0, Red)
