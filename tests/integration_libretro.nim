import
  std/[dynlib, os, strformat],
  pixie,
  decompbound/[cpu, ds_companion, frame_step, libretro_api, png_state, ppu, replay_run,
    rom_pipeline, save_state, snesbus, viewport_geometry]

const
  CorePath = "bin/libretro/decompbound_libretro.so"
  Frames = 1200
  WramOffset = 0x7E0000
  WramSize = 0x20000
  SingleSampleStart = 400
  MutedStart = 500
  BatchResume = 600

type
  VoidProc = proc() {.cdecl.}
  LoadGame = proc(info: ptr RetroGameInfo): bool {.cdecl.}
  Unserialize = proc(data: pointer, size: csize_t): bool {.cdecl.}
  MemoryData = proc(id: cuint): pointer {.cdecl.}
  SetEnvironment = proc(callback: RetroEnvironment) {.cdecl.}
  SetVideo = proc(callback: RetroVideoRefresh) {.cdecl.}
  SetAudio = proc(callback: RetroAudioSample) {.cdecl.}
  SetBatch = proc(callback: RetroAudioSampleBatch) {.cdecl.}
  SetPoll = proc(callback: RetroInputPoll) {.cdecl.}
  SetInput = proc(callback: RetroInputState) {.cdecl.}

var
  expectedImage: Image
  expectedCompanion: DsCompanion
  expectedPcm: FramePcm
  buttons: uint16
  failure: string
  videoCalls, audioFrames, pollCalls, nonzeroAudio, coloredPixels: int
  dualScreen, opaqueTransport: bool
  privateRequests, standardRequests: int
  companionInputCalls: int
  viewport = viewportGeometry()
  widthValue, heightValue: string

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Negotiate software pixels and retain errors until the callback returns.
  if command == MonoRetroEnvSetPixelFormat:
    inc privateRequests
    result = opaqueTransport and data != nil and
      cast[ptr uint32](data)[] == MonoRetroPixelFormatXbgr8888
  elif command == RetroEnvSetPixelFormat:
    inc standardRequests
    result = data != nil and cast[ptr cuint](data)[] == RetroPixelFormatXrgb8888
  elif command == RetroEnvShutdown:
    failure = "Core requested shutdown."
    result = true
  elif command == RetroEnvSetVariables:
    result = true
  elif command == RetroEnvGetVariable and data != nil:
    let setting = cast[ptr RetroVariable](data)
    if $setting.key == "decompbound_dual_screen":
      setting.value = if dualScreen: "enabled" else: "disabled"
      result = true
    elif $setting.key == ViewportWidthOption:
      setting.value = widthValue.cstring
      result = true
    elif $setting.key == ViewportHeightOption:
      setting.value = heightValue.cstring
      result = true

proc deliveredPixel(data: pointer, index: int): uint32 =
  ## Normalize negotiated RGB while checking every opaque transport filler byte.
  if opaqueTransport:
    let
      bytes = cast[ptr UncheckedArray[uint8]](data)
      offset = index * 4
    if bytes[offset + 3] != 255:
      failure = &"Opaque pixel {index} has filler {bytes[offset + 3]}, expected 255."
    result = (bytes[offset].uint32 shl 16) or
      (bytes[offset + 1].uint32 shl 8) or bytes[offset + 2].uint32
  else:
    result = cast[ptr UncheckedArray[uint32]](data)[index]

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Compare every output pixel with the independent headless frame.
  inc videoCalls
  if data == nil or width != viewport.width.cuint or
      height != viewport.outputHeight(dualScreen).cuint or
      pitch != (width * 4).csize_t:
    failure = "Invalid video buffer or geometry."
    return
  for index, color in expectedImage.data:
    let
      expected = (color.r.uint32 shl 16) or (color.g.uint32 shl 8) or color.b.uint32
      destination = ((index div ppu.ScreenWidth) + (viewport.height - ppu.ScreenHeight) div 2) *
        viewport.width + index mod ppu.ScreenWidth + (viewport.width - ppu.ScreenWidth) div 2
      actual = deliveredPixel(data, destination)
    if actual != expected:
      failure = &"Pixel {index}: {actual:08X} != {expected:08X}."
      return
    if expected != 0:
      inc coloredPixels
  if dualScreen:
    for index, color in expectedCompanion.image.data:
      let expected = (color.r.uint32 shl 16) or (color.g.uint32 shl 8) or color.b.uint32
      let destination = (viewport.height + index div ppu.ScreenWidth) * viewport.width +
        (viewport.width - ppu.ScreenWidth) div 2 + index mod ppu.ScreenWidth
      if deliveredPixel(data, destination) != expected:
        failure = &"Companion pixel {index} differs from the live WRAM/CGRAM snapshot."
        return
    for row in 0 ..< ppu.ScreenHeight:
      for column in 0 ..< viewport.width:
        let left = (viewport.width - ppu.ScreenWidth) div 2
        if column < left or column >= left + ppu.ScreenWidth:
          if deliveredPixel(data, (viewport.height + row) * viewport.width + column) != 0:
            failure = "Companion padding is not opaque black."
            return

proc sample(left, right: int16) {.cdecl.} =
  ## Compare one stereo sample without throwing through the foreign ABI.
  if audioFrames >= ApuSamplesPerFrame:
    failure = "Too many audio samples."
    return
  if left != expectedPcm[audioFrames * 2] or right != expectedPcm[audioFrames * 2 + 1]:
    failure = &"PCM mismatch at stereo sample {audioFrames}."
  if left != 0 or right != 0:
    inc nonzeroAudio
  inc audioFrames

proc batch(data: ptr int16, count: csize_t): csize_t {.cdecl.} =
  ## Compare the complete stereo batch with the reference APU stream.
  if data == nil or count != ApuSamplesPerFrame.csize_t:
    failure = "Invalid audio batch."
    return count
  let samples = cast[ptr UncheckedArray[int16]](data)
  for index in 0 ..< count.int:
    sample(samples[index * 2], samples[index * 2 + 1])
  count

proc poll() {.cdecl.} =
  ## Count the input snapshot requests for this frame.
  inc pollCalls

proc input(port, device, index, id: cuint): int16 {.cdecl.} =
  ## Supply a deterministic RetroPad input sequence.
  if port == 0 and device == RetroDeviceJoypad and index == 0 and id < 14:
    if id >= 12: inc companionInputCalls
    result = ((buttons shr id) and 1).int16

proc symbol[T](library: LibHandle, name: string): T =
  ## Resolve a required function from the actual shared library.
  let address = symAddr(library, name)
  doAssert address != nil, "Missing symbol: " & name
  cast[T](address)

proc checkMode(enabled, opaque: bool, width = 256, height = 224, frames = Frames) =
  ## Compare actual shared-library execution with cold-boot ROM emulation.
  dualScreen = enabled
  viewport = viewportGeometry(width, height)
  widthValue = $width
  heightValue = $height
  opaqueTransport = opaque
  privateRequests = 0
  standardRequests = 0
  failure = ""
  coloredPixels = 0
  nonzeroAudio = 0
  companionInputCalls = 0
  let
    rom = readGoldBaserom()
    library = loadLib(CorePath)
  doAssert library != nil, "Run make libretro first."
  defer: unloadLib(library)
  let
    init = symbol[VoidProc](library, "retro_init")
    deinit = symbol[VoidProc](library, "retro_deinit")
    load = symbol[LoadGame](library, "retro_load_game")
    unload = symbol[VoidProc](library, "retro_unload_game")
    run = symbol[VoidProc](library, "retro_run")
    memory = symbol[MemoryData](library, "retro_get_memory_data")
    setAudio = symbol[SetAudio](library, "retro_set_audio_sample")
    setBatch = symbol[SetBatch](library, "retro_set_audio_sample_batch")
  symbol[SetEnvironment](library, "retro_set_environment")(environment)
  symbol[SetVideo](library, "retro_set_video_refresh")(video)
  symbol[SetPoll](library, "retro_set_input_poll")(poll)
  symbol[SetInput](library, "retro_set_input_state")(input)
  setAudio(sample)
  setBatch(batch)
  init()
  defer: deinit()
  var game = RetroGameInfo(data: rom[0].unsafeAddr, size: rom.len.csize_t)
  doAssert load(addr game), "Core rejected the user's ROM."
  defer: unload()
  let reference = newSnesBus(rom)
  var referenceCpu = reference.resetCpu()
  var importedBytes, stateBytes: seq[uint8]
  if paramCount() == 1:
    importedBytes = cast[seq[uint8]](readFile(paramStr(1)))
    doAssert symbol[Unserialize](library, "retro_unserialize")(unsafeAddr importedBytes[0], importedBytes.len.csize_t),
      "Core rejected the supplied startup state"
    stateBytes = importedBytes
    if stateBytes.len >= PngSignature.len and stateBytes[0 ..< PngSignature.len] == @PngSignature:
      stateBytes = extractStateForRom(stateBytes, romHashOf(rom))
    deserializeState(stateBytes, reference, referenceCpu)
  expectedImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  if dualScreen: expectedCompanion = newDsCompanion(rom)
  for frame in 0 ..< frames:
    if frame == frames div 2 and importedBytes.len > 0:
      doAssert symbol[Unserialize](library, "retro_unserialize")(
        unsafeAddr importedBytes[0], importedBytes.len.csize_t), "Core rejected a live state import"
      deserializeState(stateBytes, reference, referenceCpu)
      if dualScreen: expectedCompanion = newDsCompanion(rom)
    case (frame div 45) mod 4
    of 1: buttons = 1'u16 shl 3
    of 2: buttons = 1'u16 shl 8
    of 3: buttons = 1'u16 shl 5
    else: buttons = 0
    if dualScreen:
      buttons = buttons or (if frame mod 40 < 20: 1'u16 shl 12 else: 1'u16 shl 13)
    reference.joy1 = 0
    for id in 0 ..< 12:
      if (buttons and (1'u16 shl id)) != 0:
        reference.joy1 = reference.joy1 or (1'u16 shl (15 - id))
    expectedImage.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(reference, referenceCpu, expectedImage, addr expectedPcm)
    if dualScreen:
      expectedCompanion.update(reference.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
        buttons and (PreviousMember or NextMember), DsPointer(),
        partyBattleVisible(reference.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
          (reference.ppuRegs[0x05] and 7).int), reference.cgram.toOpenArray(0, 31))
    if frame == SingleSampleStart:
      setBatch(nil)
    elif frame == MutedStart:
      setAudio(nil)
    elif frame == BatchResume:
      setAudio(sample)
      setBatch(batch)
    videoCalls = 0
    audioFrames = 0
    pollCalls = 0
    run()
    doAssert failure.len == 0, &"Frame {frame}: {failure}"
    doAssert videoCalls == 1 and pollCalls == 1
    let expectedSamples = if frame >= MutedStart and frame < BatchResume: 0 else: ApuSamplesPerFrame
    doAssert audioFrames == expectedSamples, &"Frame {frame}: {audioFrames} audio frames."
    doAssert equalMem(memory(RetroMemorySystemRam), reference.bus.mem[WramOffset].addr, WramSize),
      &"Frame {frame}: WRAM differs."
    doAssert equalMem(memory(RetroMemorySaveRam), reference.sram[0].addr, reference.sram.len),
      &"Frame {frame}: SRAM differs."
  doAssert coloredPixels > 0, "The ROM never produced a colored frame."
  doAssert nonzeroAudio > 0, "The ROM never produced audible samples."
  doAssert companionInputCalls == (if dualScreen: frames * 2 else: 0)
  doAssert privateRequests == 1
  doAssert standardRequests == (if opaqueTransport: 0 else: 1)
  echo &"libretro ROM parity (dual={dualScreen}, opaqueXBGR={opaqueTransport}, viewport={width}x{height}): {frames} frames, pixels/PCM/WRAM/SRAM matched."

checkMode(false, false)
checkMode(true, false)
checkMode(false, true)
checkMode(true, true)
if paramCount() == 1:
  for (width, height) in [(320, 240), (336, 256), (448, 252), (512, 384), (257, 225)]:
    for opaque in [false, true]:
      checkMode(true, opaque, width, height, 90)
  checkMode(false, true, 336, 256, 90)
