import
  std/[dynlib, strformat],
  pixie,
  decompbound/[cpu, frame_step, libretro_api, ppu, replay_run, rom_pipeline, snesbus]

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
  MemoryData = proc(id: cuint): pointer {.cdecl.}
  SetEnvironment = proc(callback: RetroEnvironment) {.cdecl.}
  SetVideo = proc(callback: RetroVideoRefresh) {.cdecl.}
  SetAudio = proc(callback: RetroAudioSample) {.cdecl.}
  SetBatch = proc(callback: RetroAudioSampleBatch) {.cdecl.}
  SetPoll = proc(callback: RetroInputPoll) {.cdecl.}
  SetInput = proc(callback: RetroInputState) {.cdecl.}

var
  expectedImage: Image
  expectedPcm: FramePcm
  buttons: uint16
  failure: string
  videoCalls, audioFrames, pollCalls, nonzeroAudio, coloredPixels: int
  dualScreen: bool
  companionInputCalls: int

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Negotiate software pixels and retain errors until the callback returns.
  if command == RetroEnvSetPixelFormat:
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

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Compare every output pixel with the independent headless frame.
  inc videoCalls
  if data == nil or width != ppu.ScreenWidth.cuint or
      height != (if dualScreen: ppu.ScreenHeight.cuint * 2 else: ppu.ScreenHeight.cuint) or
      pitch != (width * 4).csize_t:
    failure = "Invalid video buffer or geometry."
    return
  let pixels = cast[ptr UncheckedArray[uint32]](data)
  for index, color in expectedImage.data:
    let expected = (color.r.uint32 shl 16) or (color.g.uint32 shl 8) or color.b.uint32
    if pixels[index] != expected:
      failure = &"Pixel {index}: {pixels[index]:08X} != {expected:08X}."
      return
    if expected != 0:
      inc coloredPixels

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

proc checkMode(enabled: bool) =
  ## Compare actual shared-library execution with cold-boot ROM emulation.
  dualScreen = enabled
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
  expectedImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for frame in 0 ..< Frames:
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
  doAssert companionInputCalls == (if dualScreen: Frames * 2 else: 0)
  echo &"libretro ROM parity (dual={dualScreen}): {Frames} frames, pixels/PCM/WRAM/SRAM matched; muted and per-sample paths included."

checkMode(false)
checkMode(true)
