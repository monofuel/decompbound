import
  std/unittest,
  pixie,
  decompbound/[battle_bg, battle_viewport, battle_viewport_scroll, party_wram, ppu, snesbus]

const
  Wram = 0x7E0000
  BattlerPointer = 0x4DC8
  MainMap = 0x5000
  SubMap = 0x5400
  MainChr = 0x1000
  SubChr = 0x3000

proc fixture(): SnesBus =
  ## Construct authored two-bit textures with flips, palettes and unrelated foreground UI.
  result = newSnesBus(newSeq[uint8](0x10000))
  result.bus.mem[Wram + BattlerPointer] = (PartyCharTableWram and 255).uint8
  result.bus.mem[Wram + BattlerPointer + 1] = (PartyCharTableWram shr 8).uint8
  result.ppuRegs[0] = 15
  result.ppuRegs[5] = 8
  result.ppuRegs[9] = 0x50
  result.ppuRegs[10] = 0x54
  result.ppuRegs[12] = 0x31
  result.ppuRegs[0x30] = 2
  result.ppuRegs[0x31] = 0x64
  result.fixedColorR = 5
  result.fixedColorG = 6
  result.fixedColorB = 7
  for tile in 0 .. 3:
    for y in 0 .. 7:
      var planes: uint16
      for x in 0 .. 7:
        let index = (tile + x + y) mod 4
        planes = planes or ((index and 1) shl (7 - x)).uint16 or
          (((index shr 1) and 1) shl (15 - x)).uint16
      result.vram[MainChr + tile * 8 + y] = planes
      result.vram[SubChr + tile * 8 + y] = planes
  for y in 0 .. 31:
    for x in 0 .. 31:
      let word = ((x + y) mod 4 or (((x div 4) and 7) shl 10) or
        ((x and 1) shl 14) or ((y and 1) shl 15)).uint16
      result.vram[MainMap + y * 32 + x] = word
      result.vram[SubMap + y * 32 + x] = word

proc release(machine: SnesBus) =
  ## Release the fixture's emulator callback cycles.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc colorWord(index, line: int): uint16 =
  ## Generate a synthetic per-scanline palette independently of the renderer.
  ((index and 31) or (((index * 3 + line) and 31) shl 5) or
    (((index * 7) and 31) shl 10)).uint16

proc putWord(machine: SnesBus, offset, value: int) =
  ## Write authored WRAM fixture fields without embedding captured game memory.
  machine.bus.mem[Wram + offset] = (value and 255).uint8
  machine.bus.mem[Wram + offset + 1] = ((value shr 8) and 255).uint8

proc texture(x, y: int): tuple[index, palette: int] =
  ## Sample the authored texture by arithmetic rather than decoding its VRAM representation.
  let
    tx = (x and 255) div 8
    ty = (y and 255) div 8
    px = if (tx and 1) != 0: 7 - (x and 7) else: x and 7
    py = if (ty and 1) != 0: 7 - (y and 7) else: y and 7
  ((tx + ty + px + py) mod 4, ((tx div 4) and 7) * 4)

proc expected(x, line: int): ColorRGBX =
  ## Compute the expected background without PPU sampling, including transparent half-add rules.
  let
    a = texture(x + line * 3, line + line div 2)
    b = texture(x + line * 5 + 11, line * 2 + 7)
    main = if a.index == 0 or line < 16: colorWord(0, line)
      else: colorWord(64 + a.palette + a.index, line)
  var value = main
  # CGADSUB=$64 enables both BG3 and backdrop math; transparency does not disable the latter.
  block:
    let sub = if b.index == 0: (5 or (6 shl 5) or (7 shl 10)).uint16
      else: colorWord(96 + b.palette + b.index, line)
    value = 0
    for shift in [0, 5, 10]:
      var channel = ((main.int shr shift) and 31) + ((sub.int shr shift) and 31)
      if b.index != 0: channel = channel div 2
      value = value or (min(31, channel) shl shift).uint16
  bgr555ToColor(value).rgbx

suite "Live battle viewport":
  test "auxiliary PPU rows preserve the game's sprite visibility and colour context":
    let machine = fixture()
    defer: machine.release()
    machine.ppuRegs[0x2C] = 0x10
    machine.ppuRegs[0x2D] = 0
    machine.ppuRegs[0x31] = 0
    machine.cgram[129] = 0x001F
    for row in 0 .. 7: machine.vram[row] = 0x00FF
    for sprite in 0 ..< 128: machine.oam[sprite * 4 + 1] = 240
    machine.oam[1] = 255
    let
      expected = newImage(ScreenWidth, ScreenHeight)
      actual = newImage(ScreenWidth, ScreenHeight)
      auxiliary = SnesBus()
      auxiliaryLine = newImage(ScreenWidth, 1)
    for line in 0 ..< ScreenHeight: machine.renderScanline(expected, line)
    machine.renderSprites(expected)
    doAssert expected[0, 0] == rgbx(255, 0, 0, 255), "Sprite fixture did not actually draw"
    for line in 0 ..< ScreenHeight: machine.renderScanline(actual, line)
    auxiliary.ppuRegs[0] = 15
    auxiliary.ppuRegs[0x30] = 0xF0
    auxiliary.renderDetachedScanline(auxiliaryLine, 0)
    machine.renderSprites(actual)
    doAssert actual.data == expected.data
  test "a displayed constant suffix does not flatten the generated vertical continuation":
    let machine = fixture()
    defer: machine.release()
    var
      background: BattleBg
      rom = newSeq[uint8](0xB525)
    for i in 0 ..< 256:
      let value = clamp((if i < 64: i * 2
        elif i < 192: 256 - i * 2 else: i * 2 - 512), -128, 127)
      background.sine[i] = value
      rom[0xB425 + i] = (value and 255).uint8
    let
      segment = DistortSegment(kind: 3, frequency: 0x100, amplitude: 0x4200,
        angle: 17, compression: 0x100)
      generated = distortionLines(background, @[segment], 0, 159, 107, ScreenHeight)
      reference = newBattleViewport(336, 256, rom)
      stamped = newBattleViewport(336, 256, rom)
    machine.bus.mem[Wram + 0xADD4 + 0x68] = 3
    for (offset, value) in [(0x69, segment.frequency), (0x6B, segment.amplitude),
        (0x6E, segment.compression)]:
      machine.putWord(0xADD4 + offset, value)
    machine.bus.mem[Wram + 0xADD4 + 0x6D] = segment.angle.uint8
    machine.putWord(0x3B, 107)
    machine.hdmaen = 1 shl 5
    machine.dmaRegs[0x50] = 0x42
    machine.dmaRegs[0x51] = 0x12
    machine.dmaRegs[0x57] = 0x7E
    machine.hdmaIndirectAddr[5] = 0x3C48
    machine.ppuRegs[0x2C] = 0x15
    machine.ppuRegs[0x2D] = 8
    for index in 0 ..< 256: machine.cgram[index] = colorWord(index, 0)
    for line in 0 ..< ScreenHeight: machine.putWord(0x3C46 + line * 2, generated.dy[line])
    for variant in 0 .. 1:
      let view = if variant == 0: reference else: stamped
      for line in 0 ..< ScreenHeight:
        machine.bgScroll[4] = 159
        machine.bgScroll[5] = (if variant == 1 and line >= 184: 107
          else: generated.dy[line] and 1023).uint16
        view.captureScanline(machine, line)
      view.finishCapture(machine)
      check view.ready
    var colored = 0
    for y in 0 ..< 256:
      if y in 16 .. 239: continue
      for x in 0 ..< 336:
        doAssert reference.output[x, y] == stamped.output[x, y]
        let color = stamped.output[x, y]
        if color.r != 0 or color.g != 0 or color.b != 0: inc colored
    check colored > 0
  test "restore-time model matching covers every distortion kind and signed extra rows":
    var background: BattleBg
    for i in 0 ..< 256:
      background.sine[i] = clamp((if i < 64: i * 2
        elif i < 192: 256 - i * 2 else: i * 2 - 512), -128, 127)
    for kind in 1 .. 4:
      let
        segment = DistortSegment(kind: kind, frequency: 0x100,
          amplitude: 0x4200, angle: 17, compression: 0x100)
        lines = distortionLines(background, @[segment], 0, 159, 107, ScreenHeight)
        parameters = DistortionState(kind: kind, frequency: segment.frequency,
          amplitude: segment.amplitude, angle: segment.angle, compression: segment.compression,
          frequencyStep: 5, amplitudeStep: 512, angleStep: 3, compressionStep: 16)
      var rows: array[ScreenHeight, BattleScroll]
      for line in 0 ..< ScreenHeight:
        rows[line] = (lines.dx[line] and 1023, lines.dy[line] and 1023)
      var queued = parameters
      queued.frequency += queued.frequencyStep
      queued.amplitude += queued.amplitudeStep
      queued.angle += queued.angleStep
      queued.compression += queued.compressionStep
      let model = fitScroll(background.sine, rows, [queued])
      check model.valid
      for line in [-384, -16, 224, 512]:
        var shifted = segment
        shifted.angle = (segment.angle + line) and 255
        let shiftedY = if kind >= 3: (107 + line) and 255 else: 107
        let expected = distortionLines(background, @[shifted], 0, 159, shiftedY, 1)
        doAssert model.valueAt(background.sine, line) ==
          (expected.dx[0] and 1023, expected.dy[0] and 1023)
      rows[112].x = rows[112].x xor 1
      check not fitScroll(background.sine, rows, [queued]).valid
      if kind == 4:
        for line in 0 ..< ScreenHeight:
          rows[line] = (lines.dy[line] and 1023, 107)
        let routed = fitScroll(background.sine, rows, [queued])
        check routed.valid
        for line in 0 ..< ScreenHeight:
          doAssert routed.valueAt(background.sine, line) == rows[line]
  test "static battle textures fill every added row and column at integer and odd sizes":
    let machine = fixture()
    defer: machine.release()
    machine.ppuRegs[0x2C] = 0x15
    machine.ppuRegs[0x2D] = 8
    for index in 0 ..< 1024:
      machine.vram[MainMap + index] = 1
      machine.vram[SubMap + index] = 2
    for index in 0 ..< 256: machine.cgram[index] = colorWord(index, 0)
    let reference = newImage(ScreenWidth, ScreenHeight)
    for line in 0 ..< 8: machine.renderScanline(reference, line)
    for (width, height) in [(336, 256), (512, 384), (257, 225)]:
      let
        view = newBattleViewport(width, height)
        left = (width - ScreenWidth) div 2
        top = (height - ScreenHeight) div 2
      for line in 0 ..< ScreenHeight: view.captureScanline(machine, line)
      view.finishCapture(machine)
      check view.ready
      for y in 0 ..< height:
        for x in 0 ..< width:
          if x >= left and x < left + ScreenWidth and y >= top and y < top + ScreenHeight:
            continue
          doAssert view.output[x, y] == reference[(x - left) and 7, (y - top) and 7]
  test "live row palettes, HDMA scroll, wrapping and UI isolation at every side pixel":
    let machine = fixture()
    defer: machine.release()
    for (width, height) in [(320, 240), (336, 256), (512, 384), (257, 225)]:
      let view = newBattleViewport(width, height)
      let left = (width - ScreenWidth) div 2
      let top = (height - ScreenHeight) div 2
      for line in 0 ..< ScreenHeight:
        machine.ppuRegs[0x2C] = if line < 16: 0x11 else: 0x15
        machine.ppuRegs[0x2D] = 8
        machine.bgScroll[4] = (line * 3).uint16
        machine.bgScroll[5] = (line div 2).uint16
        machine.bgScroll[6] = (line * 5 + 11).uint16
        machine.bgScroll[7] = (line + 7).uint16
        for index in 0 ..< 256: machine.cgram[index] = colorWord(index, line)
        view.captureScanline(machine, line)
      machine.vram[0x7000] = machine.vram[0x7000] xor 1
      view.finishCapture(machine)
      check view.ready
      for line in 0 ..< ScreenHeight:
        for x in 0 ..< width:
          if x >= left and x < left + ScreenWidth: continue
          doAssert view.output[x, line + top] == expected(x - left, line),
            "Battle margin differed at " & $x & "," & $line
      machine.vram[MainChr] = machine.vram[MainChr] xor 1
      view.finishCapture(machine)
      check not view.ready
      machine.vram[MainChr] = machine.vram[MainChr] xor 1
  test "incomplete frames and non-battle modes cannot retain old margins":
    let machine = fixture()
    defer: machine.release()
    let view = newBattleViewport(336, 256)
    view.captureScanline(machine, 0)
    view.finishCapture(machine)
    check not view.ready
    machine.ppuRegs[5] = 9
    for line in 0 ..< ScreenHeight: view.captureScanline(machine, line)
    view.finishCapture(machine)
    check not view.ready
