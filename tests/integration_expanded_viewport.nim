import
  std/[os, strformat, strutils],
  pixie,
  decompbound/[cpu, expanded_viewport, frame_step, png_state, ppu, replay_run,
    rom_pipeline, save_state, snesbus]

const
  TestFrames = 480
  WramBase = 0x7E0000

proc release(machine: SnesBus) =
  ## Break emulator callback cycles after a private, in-memory comparison.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc putWord(machine: SnesBus, address: uint32, value: int) =
  ## Set a synthetic scroll-lane fixture through the public bus interface.
  machine.bus.write8(address, (value and 255).uint8)
  machine.bus.write8(address + 1, ((value shr 8) and 255).uint8)

proc checkCenter(image, original: Image): int =
  ## Compare every original pixel and count visible pixels in the new scenery area.
  let
    left = (image.width - ScreenWidth) div 2
    top = (image.height - ScreenHeight) div 2
  for y in 0 ..< image.height:
    for x in 0 ..< image.width:
      let color = image[x, y]
      doAssert color.a == 255, "Viewport pixels must stay opaque."
      if x >= left and x < left + ScreenWidth and y >= top and y < top + ScreenHeight:
        doAssert color == original[x - left, y - top], &"Original pixel changed at {x},{y}."
      elif color.r != 0 or color.g != 0 or color.b != 0:
        inc result

proc checkPreset(rom, state: seq[uint8], width, height: int) =
  ## Prove that expanded presentation preserves complete CPU/machine and PCM behavior.
  let
    reference = newSnesBus(rom)
    candidate = newSnesBus(rom)
    backgroundOracle = newSnesBus(rom)
    view = newExpandedViewport(rom, width, height)
    original = newImage(ScreenWidth, ScreenHeight)
    expected = newImage(ScreenWidth, ScreenHeight)
    background = newImage(ScreenWidth, ScreenHeight)
  defer: reference.release()
  defer: candidate.release()
  defer: backgroundOracle.release()
  var
    referenceCpu, candidateCpu: Cpu
    referencePcm, candidatePcm: FramePcm
    extendedFrames = 0
    horizontalBoundary, verticalBoundary = false
    horizontalSector, verticalSector: bool
    previousX, previousY: int
    capturedX, capturedY: int
  deserializeState(state, reference, referenceCpu)
  deserializeState(state, candidate, candidateCpu)
  let hook: VisibleFrameHook = proc(machine: SnesBus) =
    ## Capture only the presentation source at the pre-NMI frame boundary.
    view.capture(machine)
    (capturedX, capturedY) = view.worldOrigin
    backgroundOracle.vram = machine.vram
    backgroundOracle.cgram = machine.cgram
    backgroundOracle.ppuRegs = machine.ppuRegs
    backgroundOracle.bgScroll = machine.bgScroll
    backgroundOracle.ppuRegs[0x2C] = 3
  for frame in 0 ..< TestFrames:
    let buttons = case frame div (TestFrames div 5)
      of 1: 0x0100'u16
      of 2: 0x0200'u16
      of 3: 0x0400'u16
      of 4: 0x0800'u16
      else: 0'u16
    reference.joy1 = buttons
    candidate.joy1 = buttons
    expected.fill(rgbx(0, 0, 0, 255))
    original.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(reference, referenceCpu, expected, addr referencePcm)
    stepReplayFrame(candidate, candidateCpu, original, addr candidatePcm,
      onVisibleFrame = hook)
    doAssert original.data == expected.data
    doAssert candidatePcm == referencePcm
    let before = serializeState(candidate, candidateCpu)
    let composed = view.compose(original)
    if frame == 0:
      doAssert view.presentation.startsWith("extended"),
        &"Winters reference was rejected: {view.presentation}; " &
        &"BG maps={backgroundOracle.ppuRegs[7]:02X}/{backgroundOracle.ppuRegs[8]:02X}."
    doAssert composed.width == width and composed.height == height
    let addedPixels = checkCenter(composed, expected)
    if view.presentation.startsWith("extended"):
      inc extendedFrames
      doAssert addedPixels > 0, "An extended Winters frame must expose actual terrain."
      for y in 0 ..< ScreenHeight: backgroundOracle.renderScanline(background, y)
      for y in 0 ..< ScreenHeight:
        for x in 0 ..< ScreenWidth:
          doAssert view.sceneryPixel(capturedX + x, capturedY + y) == background[x, y],
            &"Live atlas/PPU background mismatch at frame {frame}, pixel {x},{y}; " &
            &"camera={capturedX},{capturedY} scroll={backgroundOracle.bgScroll}; " &
            &"atlas={view.sceneryPixel(capturedX + x, capturedY + y)} ppu={background[x, y]}."
    else:
      doAssert addedPixels == 0, "Padded fallback retained scenery."
    doAssert serializeState(candidate, candidateCpu) == before, "Composition changed machine state."
    doAssert before == serializeState(reference, referenceCpu),
      "Capture/stepping changed CPU or machine state."
    if frame > 0:
      horizontalBoundary = horizontalBoundary or capturedX div 8 != previousX div 8
      verticalBoundary = verticalBoundary or capturedY div 8 != previousY div 8
      horizontalSector = horizontalSector or capturedX div 256 != previousX div 256
      verticalSector = verticalSector or capturedY div 128 != previousY div 128
    previousX = capturedX
    previousY = capturedY
  doAssert extendedFrames > 0, "No Winters outdoor frames extended: " & view.presentation
  doAssert horizontalBoundary and verticalBoundary
  doAssert horizontalSector and verticalSector,
    &"The route did not cross both sector axes: horizontal={horizontalSector}, vertical={verticalSector}."
  for axis in 0 .. 1:
    candidate.bgScroll[axis + 2] = candidate.bgScroll[axis] xor 1'u16
    view.capture(candidate)
    doAssert view.presentation == "padded independent-bg-scroll"
    doAssert checkCenter(view.compose(original), original) == 0
    candidate.bgScroll[axis + 2] = candidate.bgScroll[axis]
  let mapBase = candidate.ppuRegs[7]
  candidate.ppuRegs[7] = mapBase xor 4'u8
  view.capture(candidate)
  doAssert view.presentation == "padded tilemap-base"
  doAssert checkCenter(view.compose(original), original) == 0
  candidate.ppuRegs[7] = mapBase
  candidate.ppuRegs[0] = candidate.ppuRegs[0] or 0x80'u8
  view.capture(candidate)
  doAssert checkCenter(view.compose(original), original) == 0,
    "A forced blank transition must clear all added scenery."
  candidate.ppuRegs[0] = candidate.ppuRegs[0] and 0x7F'u8
  candidate.ppuRegs[5] = 0
  view.capture(candidate)
  doAssert checkCenter(view.compose(original), original) == 0,
    "An unsupported battle-mode snapshot must use padded original presentation."
  candidate.ppuRegs[5] = 9
  let origin = view.worldOrigin
  candidate.putWord(0x7E0041, origin.x)
  candidate.putWord(0x7E0045, origin.y)
  candidate.putWord(0x7E0043, origin.x + 1024)
  candidate.putWord(0x7E0047, origin.y)
  candidate.bgScroll[0] = (origin.x and 1023).uint16
  candidate.bgScroll[1] = (origin.y and 1023).uint16
  view.capture(candidate)
  doAssert view.presentation == "padded unmatched-published-scroll"
  doAssert checkCenter(view.compose(original), original) == 0,
    "Ambiguous full-world scroll snapshots must use padded presentation."
  echo &"Viewport {width}x{height}: {extendedFrames}/{TestFrames} extended frames, " &
    &"tileCrossings={horizontalBoundary}/{verticalBoundary}, " &
    &"sectorCrossings={horizontalSector}/{verticalSector}; " &
    "original pixels, PCM, complete machine/CPU and fallback matched."

proc main() =
  ## Exercise the actual user's Winters reference without writing game-derived fixtures.
  if paramCount() != 1:
    raise newException(ValueError, "Supply the private earthbound_20260818-021632.png Winters state.")
  let
    rom = readGoldBaserom()
    bytes = cast[seq[uint8]](readFile(paramStr(1)))
    state = extractStateForRom(bytes, romHashOf(rom))
  for (width, height) in [(320, 240), (336, 256), (448, 252), (512, 384), (257, 225)]:
    checkPreset(rom, state, width, height)

main()
