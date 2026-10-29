import
  std/[os, strformat],
  pixie,
  decompbound/[cpu, frame_step, png_state, ppu, rom_pipeline, save_state,
    snesbus, world_map, world_map_assets],
  ./original_cpu

const
  PartyWorldX = 0x9877
  PartyWorldY = 0x987B
  LeaderWorldX = 0x0BBE
  LeaderWorldY = 0x0BFA
  CameraWorldX = 0x0031
  CameraWorldY = 0x0033
  HawkEyeFlagByte = 0x7E9C2B'u32
  HawkEyeFlagMask = 0x80'u8
  SceneFrames = 120
  LeftInput = 0x0200'u16

proc nonBlack(image: Image): int =
  ## Count visible background pixels without storing any captured game asset.
  for pixel in image.data:
    if pixel.r != 0 or pixel.g != 0 or pixel.b != 0: inc result

proc main() =
  ## Reproduce the counterfactual shroud scene from an explicitly supplied private capture.
  if paramCount() != 1:
    raise newException(ValueError,
      "Supply the private earthbound_20260725-183101.png pre-Hawk-Eye screenstate.")
  let
    rom = readGoldBaserom()
    machine = newSnesBus(rom)
    state = extractStateForRom(cast[seq[uint8]](readFile(paramStr(1))), romHashOf(rom))
  defer: machine.releaseOriginal()
  var cpu: Cpu
  deserializeState(state, machine, cpu)
  doAssert (machine.bus.read8(HawkEyeFlagByte) and HawkEyeFlagMask) == 0,
    "The reference must start with Hawk Eye unused."
  machine.putWord(PartyWorldX, 5088)
  machine.putWord(PartyWorldY, 7248)
  machine.putWord(LeaderWorldX, 5088)
  machine.putWord(LeaderWorldY, 7248)
  machine.joy1 = LeftInput
  for frame in 0 ..< SceneFrames:
    machine.stepOneFrame(cpu, nil, render = false)
  doAssert (machine.bus.read8(HawkEyeFlagByte) and HawkEyeFlagMask) == 0
  let
    cameraX = machine.wramWord(CameraWorldX)
    cameraY = machine.wramWord(CameraWorldY)
    original = newImage(ScreenWidth, ScreenHeight)
    atlas = newWorldMapAtlas(rom)
    resource = atlas.assets.resource(6)
  # Align animation and the other story-dependent drawing-family 6 substitutions.
  # The diagnostic compares native scene composition, not mismatched animation frames.
  for byte in 0 ..< WorldChrBytes:
    let word = machine.vram[byte div 2]
    resource.graphics[byte] = if byte mod 2 == 0: word.uint8 else: (word shr 8).uint8
  for arrangement in 0 ..< resource.arrangements.len:
    for tile in 0 ..< WorldArrangementCells:
      resource.arrangements[arrangement][tile] = machine.bus.read16(
        0x7F8000'u32 + (arrangement * WorldArrangementCells * 2 + tile * 2).uint32)
  let native = atlas.renderViewport((cameraX + ScreenWidth div 2).float64,
    (cameraY + ScreenHeight div 2).float64, 1, ScreenWidth, ScreenHeight)
  machine.ppuRegs[0x2C] = machine.ppuRegs[0x2C] and not 0x10'u8
  for y in 0 ..< ScreenHeight: machine.renderScanline(original, y)
  doAssert original.data == native.data,
    "The native scenery differs from the original engine's rebuilt background."
  # This count is diagnostic evidence, not a hardware golden preserving the defect.
  echo &"Original counterfactual shroud matched {original.data.len} pixels; " &
    &"{original.nonBlack()} non-black background pixels at camera {cameraX},{cameraY}."

main()
