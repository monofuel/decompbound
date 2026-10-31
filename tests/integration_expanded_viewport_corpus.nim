import
  std/[algorithm, os, strformat, strutils, tables],
  pixie,
  decompbound/[cpu, expanded_viewport, frame_step, png_state, ppu, replay_run,
    rom_pipeline, save_state, snesbus]

proc release(machine: SnesBus) =
  ## Break machine callback cycles between private corpus cases.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc checkStaticEffects(rom, state: seq[uint8]) =
  ## Compare synthetic lighting and window configurations against the independent PPU.
  let
    machine = newSnesBus(rom)
    view = newExpandedViewport(rom, 336, 256)
    background = newImage(ScreenWidth, ScreenHeight)
  defer: machine.release()
  var cpu: Cpu
  deserializeState(state, machine, cpu)
  let baseline = machine.ppuRegs
  for variant in 0 ..< 31:
    machine.ppuRegs = baseline
    machine.ppuRegs[0x2C] = 3
    machine.ppuRegs[0x2D] = 0
    machine.ppuRegs[0x2E] = 0
    machine.ppuRegs[0x2F] = 0
    machine.ppuRegs[0x23] = 0
    machine.ppuRegs[0x25] = 0
    machine.ppuRegs[0x30] = 0
    machine.ppuRegs[0x31] = 0
    machine.fixedColorR = 7
    machine.fixedColorG = 13
    machine.fixedColorB = 23
    for index in 0 ..< machine.cgram.len:
      machine.cgram[index] = ((index and 31) or
        (((index * 3) and 31) shl 5) or (((index * 7) and 31) shl 10)).uint16
    case variant
    of 0 .. 3:
      machine.ppuRegs[0] = [0'u8, 1, 7, 15][variant]
    of 4 .. 7:
      machine.ppuRegs[0x31] = (0x23 or ((variant - 4) shl 6)).uint8
    of 8 .. 10:
      machine.ppuRegs[0x30] = 2
      machine.ppuRegs[0x31] = 0x63
      machine.ppuRegs[0x2D] = (variant - 7).uint8
    of 11:
      machine.ppuRegs[0x2C] = 0
      machine.ppuRegs[0x2D] = 3
      machine.ppuRegs[0x30] = 2
      machine.ppuRegs[0x31] = 3
    of 12 .. 15:
      machine.ppuRegs[0x23] = 0xBA
      machine.ppuRegs[0x2E] = 3
      machine.ppuRegs[0x2A] = ((variant - 12) * 5).uint8
    else:
      machine.ppuRegs[0x25] = 0xA0
      machine.ppuRegs[0x2B] = 8
      machine.ppuRegs[0x30] = ((variant - 15) shl 4).uint8
      machine.ppuRegs[0x31] = 0xE3
    machine.ppuRegs[0x26] = 32
    machine.ppuRegs[0x27] = 128
    machine.ppuRegs[0x28] = 96
    machine.ppuRegs[0x29] = 192
    let before = serializeState(machine, cpu)
    view.capture(machine)
    doAssert serializeState(machine, cpu) == before, "Capture changed the machine"
    doAssert view.presentation.startsWith("extended"), $variant & ": " & view.presentation
    let origin = view.worldOrigin
    for y in 0 ..< ScreenHeight:
      machine.renderScanline(background, y)
      for x in 0 ..< ScreenWidth:
        doAssert view.sceneryPixel(origin.x + x, origin.y + y) == background[x, y],
          &"Lighting/window variant {variant} differed at {x},{y}."

proc main() =
  ## Compare every eligible private scene against the independent PPU background renderer.
  let
    rom = readGoldBaserom()
    view = newExpandedViewport(rom, 336, 256)
    oracle = newSnesBus(rom)
    original = newImage(ScreenWidth, ScreenHeight)
    background = newImage(ScreenWidth, ScreenHeight)
  defer: oracle.release()
  var
    paths: seq[string]
    accepted, battles, rejected, noState, mismatched: int
    effectsChecked = false
    families: set[0 .. 31]
    reasons = initCountTable[string]()
  if paramCount() > 0:
    paths = commandLineParams()
  else:
    for path in walkPattern(getHomeDir() / "Pictures/Screenshots/earthbound_*.png"):
      paths.add(path)
    paths.sort()
  doAssert paths.len > 0, "Supply private state screenshots or populate the local archive."
  for path in paths:
    let
      bytes = cast[seq[uint8]](readFile(path))
      name = path.extractFilename
    var state: seq[uint8]
    try:
      state = extractStateForRom(bytes, romHashOf(rom))
    except ValueError as error:
      if error.msg != "PNG has no embedded ebSt save-state": raise
      inc noState
      continue
    let machine = newSnesBus(rom)
    defer: machine.release()
    var cpu: Cpu
    deserializeState(state, machine, cpu)
    let hook: VisibleFrameHook = proc(snes: SnesBus) =
      ## Preserve the source snapshot while isolating map layers from original actors and UI.
      let before = serializeState(snes, cpu)
      view.capture(snes)
      doAssert serializeState(snes, cpu) == before, name & ": capture changed machine"
      if not effectsChecked and view.presentation == "extended map":
        checkStaticEffects(rom, before)
        effectsChecked = true
      oracle.vram = snes.vram
      oracle.cgram = snes.cgram
      oracle.ppuRegs = snes.ppuRegs
      oracle.bgScroll = snes.bgScroll
      oracle.fixedColorR = snes.fixedColorR
      oracle.fixedColorG = snes.fixedColorG
      oracle.fixedColorB = snes.fixedColorB
      oracle.ppuRegs[0x2C] = snes.ppuRegs[0x2C] and 3
      oracle.ppuRegs[0x2D] = snes.ppuRegs[0x2D] and 3
    let scanline: ScanlineHook = proc(snes: SnesBus, line: int) =
      ## Exercise the same optional live-row observer used by the libretro caller.
      view.captureScanline(snes, line)
    original.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(machine, cpu, original, onVisibleFrame = hook, onScanline = scanline)
    let before = serializeState(machine, cpu)
    let composed = view.compose(original)
    let left = (composed.width - ScreenWidth) div 2
    let top = (composed.height - ScreenHeight) div 2
    for y in 0 ..< ScreenHeight:
      for x in 0 ..< ScreenWidth:
        doAssert composed[x + left, y + top] == original[x, y], name & ": original changed"
    doAssert serializeState(machine, cpu) == before, name & ": compose changed machine"
    if view.presentation == "extended battle":
      inc battles
      continue
    if view.presentation != "extended map":
      inc rejected
      reasons.inc(view.presentation)
      continue
    inc accepted
    let logical = machine.bus.read16(0x7E436E).int
    families.incl(logical)
    let origin = view.worldOrigin
    var differences = 0
    var first: tuple[x, y: int]
    for y in 0 ..< ScreenHeight:
      oracle.renderScanline(background, y)
      for x in 0 ..< ScreenWidth:
        if view.sceneryPixel(origin.x + x, origin.y + y) != background[x, y]:
          if differences == 0: first = (x, y)
          inc differences
    if differences > 0:
      inc mismatched
      echo &"MISMATCH {name} logical={logical} xy={origin} pixels={differences} first={first} " &
        &"atlas={view.sceneryPixel(origin.x + first.x, origin.y + first.y)} ppu={background[first.x, first.y]}"
  echo &"Corpus: maps={accepted}, battles={battles}, padded={rejected}, imageOnly={noState}, " &
    &"families={families}, mismatched={mismatched}; fallback={reasons}"
  doAssert accepted > 0, "No map scene was exercised."
  doAssert effectsChecked, "Static lighting and windows were not exercised."
  if paramCount() == 0:
    doAssert card(families) > 1, "The archive sweep must cover more than one logical family."
  doAssert mismatched == 0, "Expanded scenery disagrees with original PPU background."

main()
