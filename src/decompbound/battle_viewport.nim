import
  pixie,
  ./[battle_viewport_scroll, cpu, ds_companion, ppu, snesbus]

type
  BattleLine = object
    registers: array[0x100, uint8]
    colors: array[256, uint16]
    scroll: array[8, uint16]
    red, green, blue: uint8
  BattleViewport* = ref object
    ## Retain one displayed battle frame's PPU rows without advancing its animation.
    width, height, originX, originY: int
    shadow: SnesBus
    lineImage: Image
    output*: Image
    rows: array[ScreenHeight, BattleLine]
    parameters: array[2, DistortionState]
    generated: array[2, array[ScreenHeight, int]]
    published: array[2, BattleScroll]
    waveAxis: array[2, int]
    models: array[2, BattleScrollModel]
    sine: array[256, int]
    lines: int
    valid, hasBackground: bool
    ready*: bool

const
  WramOffset = 0x7E0000
  WramSize = 0x20000
  ModeReg = 0x05
  BrightnessReg = 0x00
  MosaicReg = 0x06
  Bg3MapReg = 0x09
  Bg4MapReg = 0x0A
  Bg34ChrReg = 0x0C
  MainReg = 0x2C
  SubReg = 0x2D
  MainBackground = 0x04'u8
  SubBackground = 0x08'u8
  ObjectLayer = 0x10'u8
  WindowFirstLeft = 0x26
  ScrollMask = 0x03FF
  TilemapScreenWords = 0x400
  ChrBankWords = 0x1000
  TwoBitChrWords = 0x2000
  OpaqueBlack = rgbx(0, 0, 0, 255)
  SineFile = 0x00B425
    ## C0AE5A reads the signed 256-entry wave from the user ROM at C0B425.
  DistortionBuffer = 0x3C46
  DistortionBufferBytes = ScreenHeight * sizeof(uint16)
    ## C0AE5A emits A at 3C46 and B at 3E06; C2CF29 can prepare their next frame.
  PublishedScroll = 0x0031
    ## C2CBB9 publishes the layer's ordinary scroll before its HDMA distortion.

proc newBattleViewport*(width, height: int, rom: seq[uint8] = @[]): BattleViewport =
  ## Allocate a lightweight PPU-only shadow and reusable output, without a CPU or APU.
  result = BattleViewport(width: width, height: height,
    originX: (width - ScreenWidth) div 2, originY: (height - ScreenHeight) div 2,
    shadow: SnesBus(), lineImage: newImage(ScreenWidth, 1),
    output: newImage(width, height))
  if rom.len >= SineFile + result.sine.len:
    for index in 0 ..< result.sine.len:
      result.sine[index] = cast[int8](rom[SineFile + index]).int

proc captureScanline*(view: BattleViewport, snes: SnesBus, line: int) =
  ## Record the exact post-HDMA register, palette and scroll state displayed by each row.
  if line == 0:
    view.lines = 0
    view.valid = true
    view.hasBackground = false
    view.ready = false
  if line != view.lines or line notin 0 ..< ScreenHeight:
    view.valid = false
    return
  inc view.lines
  if not view.valid: return
  let mode = snes.ppuRegs[ModeReg]
  if not partyBattleVisible(snes.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
      (mode and 7).int) or (mode and 0xC0) != 0 or
      (snes.ppuRegs[BrightnessReg] and 0x80) != 0 or snes.ppuRegs[MosaicReg] != 0:
    view.valid = false
    return
  if line == 0:
    view.shadow.vram = snes.vram
    for layer in 0 .. 1:
      view.parameters[layer] = snes.distortionState(layer)
      let
        buffer = DistortionBuffer + layer * DistortionBufferBytes
        scroll = PublishedScroll + (layer + 2) * 4
      view.published[layer] = (snes.bus.read16((WramOffset + scroll).uint32).int and ScrollMask,
        snes.bus.read16((WramOffset + scroll + 2).uint32).int and ScrollMask)
      view.waveAxis[layer] = -1
      for channel in 0 .. 7:
        let base = channel * 16
        let target = snes.dmaRegs[base + 1].int - (0x11 + layer * 2)
        if (snes.hdmaen and (1'u8 shl channel)) != 0 and target in 0 .. 1 and
            (snes.dmaRegs[base] and 0x40) != 0 and snes.dmaRegs[base + 7] == 0x7E and
            snes.hdmaIndirectAddr[channel].int in buffer .. buffer + 2:
          view.waveAxis[layer] = target
      for y in 0 ..< ScreenHeight:
        view.generated[layer][y] = snes.bus.read16((WramOffset + buffer + y * 2).uint32).int and ScrollMask
  if line > 0:
    for register in [Bg3MapReg, Bg4MapReg, Bg34ChrReg]:
      if snes.ppuRegs[register] != view.rows[0].registers[register]:
        view.valid = false
        return
  view.rows[line] = BattleLine(registers: snes.ppuRegs, colors: snes.cgram,
    scroll: snes.bgScroll, red: snes.fixedColorR, green: snes.fixedColorG,
    blue: snes.fixedColorB)
  view.hasBackground = view.hasBackground or
    (snes.ppuRegs[MainReg] and MainBackground) != 0 or
    (snes.ppuRegs[SubReg] and SubBackground) != 0

proc backgroundStable(view: BattleViewport, snes: SnesBus): bool =
  ## Reject background VRAM replacement during visible drawing while allowing unrelated UI uploads.
  let registers = view.rows[0].registers
  for bg in 2 .. 3:
    let
      mapRegister = registers[0x07 + bg].int
      base = ((mapRegister shr 2) shl 10) and 0x7FFF
      screens = (if (mapRegister and 1) != 0: 2 else: 1) *
        (if (mapRegister and 2) != 0: 2 else: 1)
      chrBase = (((registers[Bg34ChrReg].int shr ((bg - 2) * 4)) and 15) *
        ChrBankWords) and 0x7FFF
    for index in 0 ..< screens * TilemapScreenWords:
      let address = (base + index) and 0x7FFF
      if view.shadow.vram[address] != snes.vram[address]: return false
    for index in 0 ..< TwoBitChrWords:
      let address = (chrBase + index) and 0x7FFF
      if view.shadow.vram[address] != snes.vram[address]: return false
  true

proc shiftedWindow(shadow: SnesBus, registers: array[0x100, uint8], offset: int) =
  ## Translate window ranges into a texture chunk, preserving empty and inverted ranges.
  for first in [WindowFirstLeft, WindowFirstLeft + 2]:
    let left = registers[first].int - offset
    let right = registers[first + 1].int - offset
    if left > right or left >= ScreenWidth or right < 0:
      shadow.ppuRegs[first] = 1
      shadow.ppuRegs[first + 1] = 0
    else:
      shadow.ppuRegs[first] = clamp(left, 0, ScreenWidth - 1).uint8
      shadow.ppuRegs[first + 1] = clamp(right, 0, ScreenWidth - 1).uint8

proc renderChunk(view: BattleViewport, row: BattleLine, y, start, length: int) =
  ## Reuse the real PPU compositor on a translated background-only chunk.
  let
    shadow = view.shadow
    offset = start - view.originX
    virtualY = y - view.originY
  shadow.ppuRegs = row.registers
  shadow.cgram = row.colors
  shadow.bgScroll = row.scroll
  shadow.fixedColorR = row.red
  shadow.fixedColorG = row.green
  shadow.fixedColorB = row.blue
  # Keep a nonzero OBJ marker when UI layers existed, preserving the compositor's
  # TM=0 direct-subscreen rule while excluding centered foreground graphics.
  shadow.ppuRegs[MainReg] = (row.registers[MainReg] and MainBackground) or
    (if row.registers[MainReg] != 0: ObjectLayer else: 0'u8)
  shadow.ppuRegs[SubReg] = row.registers[SubReg] and SubBackground
  for bg in 0 .. 3:
    shadow.bgScroll[bg * 2] = ((row.scroll[bg * 2].int + offset) and ScrollMask).uint16
    shadow.bgScroll[bg * 2 + 1] = ((row.scroll[bg * 2 + 1].int + virtualY) and ScrollMask).uint16
  shadow.shiftedWindow(row.registers, offset)
  shadow.renderDetachedScanline(view.lineImage, 0)
  copyMem(addr view.output.data[y * view.width + start], addr view.lineImage.data[0],
    length * sizeof(ColorRGBX))

proc finishCapture*(view: BattleViewport, snes: SnesBus) =
  ## Draw live battle margins, retaining original framing and centered actors/UI.
  view.ready = view.valid and view.lines == ScreenHeight and view.hasBackground and
    view.backgroundStable(snes)
  if not view.ready: return
  for layer in 0 .. 1:
    var observed: array[ScreenHeight, BattleScroll]
    for line in 0 ..< ScreenHeight:
      observed[line] = (view.rows[line].scroll[4 + layer * 2].int,
        view.rows[line].scroll[5 + layer * 2].int)
    view.models[layer] = fitScroll(view.sine, observed,
      [view.parameters[layer], snes.distortionState(layer)])
    if not view.models[layer].valid and view.waveAxis[layer] >= 0:
      let axis = view.waveAxis[layer]
      var generated = observed
      var suffix = false
      var prefix = 0
      var compatible = true
      for line in 0 ..< ScreenHeight:
        let
          actual = if axis == 0: observed[line].x else: observed[line].y
          plain = if axis == 0: view.published[layer].x else: view.published[layer].y
          wave = view.generated[layer][line]
        if not suffix and actual == wave:
          inc prefix
        else:
          suffix = true
          if actual != plain: compatible = false
        if axis == 0: generated[line].x = wave
        else: generated[line].y = wave
      # Some battles replace a suffix of the displayed wave with published scroll.
      # Preserve those actual rows; continue only a fully verified original generator.
      if compatible and prefix > 0:
        view.models[layer] = fitScroll(view.sine, generated,
          [view.parameters[layer], snes.distortionState(layer)])
  view.output.fill(OpaqueBlack)
  for line in 0 ..< ScreenHeight:
    let y = line + view.originY
    var x = 0
    while x < view.originX:
      let count = min(ScreenWidth, view.originX - x)
      view.renderChunk(view.rows[line], y, x, count)
      x += count
    x = view.originX + ScreenWidth
    while x < view.width:
      let count = min(ScreenWidth, view.width - x)
      view.renderChunk(view.rows[line], y, x, count)
      x += count
  for y in 0 ..< view.height:
    let virtualY = y - view.originY
    if virtualY in 0 ..< ScreenHeight: continue
    var row = view.rows[if virtualY < 0: 0 else: ScreenHeight - 1]
    var supported = true
    for layer in 0 .. 1:
      let enabled = if layer == 0: (row.registers[MainReg] and MainBackground) != 0
        else: (row.registers[SubReg] and SubBackground) != 0
      if enabled and not view.models[layer].valid: supported = false
      if view.models[layer].valid:
        let scroll = view.models[layer].valueAt(view.sine, virtualY)
        row.scroll[4 + layer * 2] = scroll.x.uint16
        row.scroll[5 + layer * 2] = scroll.y.uint16
    if not supported: continue
    var x = 0
    while x < view.width:
      let count = min(ScreenWidth, view.width - x)
      view.renderChunk(row, y, x, count)
      x += count
