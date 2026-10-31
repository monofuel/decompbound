import
  std/[options, os, strformat, strutils],
  pixie,
  decompbound/[cpu, expanded_viewport, frame_step, png_state, ppu, replay_run,
    rom_pipeline, save_state, snesbus]

const
  SceneNames = ["earthbound_20260818-021806.png", "earthbound_20260818-021923.png",
    "earthbound_20260818-021632.png", "earthbound_20260818-021941.png"]
  Frames = 96

proc release(machine: SnesBus) =
  ## Break hardware callback cycles after each private scene comparison.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc checkLighting(rom: seq[uint8]) =
  ## Compare actor windows, brightness and fixed-colour math with the native PPU.
  let
    machine = newSnesBus(rom)
    view = newExpandedViewport(rom, 336, 256)
    image = newImage(ScreenWidth, ScreenHeight)
    state = extractStateForRom(cast[seq[uint8]](readFile(getHomeDir() /
      "Pictures/Screenshots" / SceneNames[0])), romHashOf(rom))
  defer: machine.release()
  defer: view.detachSprites()
  var cpu: Cpu
  deserializeState(state, machine, cpu)
  view.attachSprites(machine)
  for warmup in 0 ..< 3: stepReplayFrame(machine, cpu)
  view.capture(machine)
  doAssert view.spriteStatus == "matched"
  let
    origin = view.worldOrigin
    registers = machine.ppuRegs
  var samples: seq[tuple[x, y: int]]
  for y in 0 ..< ScreenHeight:
    for x in 0 ..< ScreenWidth:
      if view.actorPixel(origin.x + x, origin.y + y).isSome: samples.add((x, y))
  doAssert samples.len > 0
  for variant in 0 ..< 24:
    machine.ppuRegs = registers
    machine.ppuRegs[0] = [0'u8, 7, 15][variant mod 3]
    machine.ppuRegs[0x2C] = 0x13
    machine.ppuRegs[0x2D] = 0
    machine.ppuRegs[0x2E] = if variant >= 12: 0x10'u8 else: 0'u8
    machine.ppuRegs[0x2F] = 0
    machine.ppuRegs[0x25] = 0xAA
    machine.ppuRegs[0x26] = 32
    machine.ppuRegs[0x27] = 128
    machine.ppuRegs[0x28] = 96
    machine.ppuRegs[0x29] = 192
    machine.ppuRegs[0x2B] = ((variant div 3) and 15).uint8
    machine.ppuRegs[0x30] = (((variant div 6) shl 6) or ((variant mod 4) shl 4)).uint8
    machine.ppuRegs[0x31] = (0x10 or ((variant mod 4) shl 6)).uint8
    machine.fixedColorR = 7
    machine.fixedColorG = 13
    machine.fixedColorB = 23
    let before = serializeState(machine, cpu)
    view.capture(machine)
    doAssert view.presentation == "extended map"
    for y in 0 ..< ScreenHeight: machine.renderScanline(image, y)
    machine.renderSprites(image)
    machine.overlayForegroundBg(image)
    for point in samples:
      doAssert view.scenePixel(origin.x + point.x, origin.y + point.y) == image[point.x, point.y],
        &"OBJ lighting variant={variant} xy={point} " &
        &"scene={view.scenePixel(origin.x+point.x, origin.y+point.y)} native={image[point.x,point.y]}"
    doAssert serializeState(machine, cpu) == before

proc checkScene(rom: seq[uint8], name: string, width, height: int): tuple[matched, margin, compared: int] =
  ## Compare live sprites with native pixels while proving complete machine and PCM invariance.
  let
    state = extractStateForRom(cast[seq[uint8]](readFile(getHomeDir() /
      "Pictures/Screenshots" / name)), romHashOf(rom))
    candidate = newSnesBus(rom)
    reference = newSnesBus(rom)
    view = newExpandedViewport(rom, width, height)
    original = newImage(ScreenWidth, ScreenHeight)
    expected = newImage(ScreenWidth, ScreenHeight)
  defer: candidate.release()
  defer: reference.release()
  defer: view.detachSprites()
  var
    cpu, referenceCpu: Cpu
    pcm, expectedPcm: FramePcm
  deserializeState(state, candidate, cpu)
  deserializeState(state, reference, referenceCpu)
  view.attachSprites(candidate)
  let
    capture: VisibleFrameHook = proc(machine: SnesBus) =
      ## Freeze map and actor presentation at the same boundary as the core.
      view.capture(machine)
    scanline: ScanlineHook = proc(machine: SnesBus, line: int) =
      ## Preserve the existing line-effect observer.
      view.captureScanline(machine, line)
  for frame in 0 ..< Frames:
    let buttons = if frame < 24: 0'u16 elif frame < 60: 0x0100'u16 else: 0x0200'u16
    candidate.joy1 = buttons
    reference.joy1 = buttons
    stepReplayFrame(reference, referenceCpu, expected, addr expectedPcm)
    stepReplayFrame(candidate, cpu, original, addr pcm,
      onVisibleFrame = capture, onScanline = scanline)
    doAssert original.data == expected.data, name & ": native pixels changed"
    doAssert pcm == expectedPcm, name & ": PCM changed"
    let before = serializeState(candidate, cpu)
    doAssert before == serializeState(reference, referenceCpu), name & ": emulation changed"
    let image = view.compose(original)
    doAssert serializeState(candidate, cpu) == before, name & ": compose wrote state"
    let
      left = (width - ScreenWidth) div 2
      top = (height - ScreenHeight) div 2
      origin = view.worldOrigin
    for y in 0 ..< ScreenHeight:
      for x in 0 ..< ScreenWidth:
        doAssert image[x + left, y + top] == expected[x, y]
    if view.presentation == "extended map" and view.spriteStatus == "matched":
      inc result.matched
      for y in 0 ..< height:
        for x in 0 ..< width:
          let actor = view.actorPixel(origin.x + x - left, origin.y + y - top)
          if actor.isNone: continue
          if x >= left and x < left + ScreenWidth and y >= top and y < top + ScreenHeight:
            inc result.compared
            doAssert actor.get == original[x - left, y - top],
              &"{name} frame={frame} actor differs at {x-left},{y-top}: " &
              &"actor={actor.get}, native={original[x-left,y-top]}"
          else:
            inc result.margin
            doAssert image[x, y] == actor.get
    if frame == Frames - 1:
      echo &"{name} {width}x{height}: status={view.spriteStatus}, pixels={view.spritePixels}"
  echo &"  matched={result.matched}, nativeActorPixels={result.compared}, marginActorPixels={result.margin}"

proc main() =
  ## Exercise ordinary active NPCs and player movement without speakers or stored captures.
  let rom = readGoldBaserom()
  checkLighting(rom)
  var matched, margin, compared: int
  for name in SceneNames:
    for (width, height) in [(336, 256), (512, 384)]:
      let counts = checkScene(rom, name, width, height)
      matched += counts.matched
      margin += counts.margin
      compared += counts.compared
  doAssert matched > 0, "No genuine published OAM generation was consumed"
  doAssert margin > 0, "No expanded actor pixels were exercised"
  doAssert compared > 0, "No actor pixels were checked against the native renderer"

main()
