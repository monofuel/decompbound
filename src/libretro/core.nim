## A single-instance libretro adapter around the headless SNES emulator.

import
  pixie,
  ../decompbound/[apu, build_info, common, core_profile, cpu, ds_companion, frame_step,
    libretro_api, png_state, ppu, replay_run, save_state, snesbus]

const
  Width = ppu.ScreenWidth
  Height = ppu.ScreenHeight
  RomSize = EarthboundRomSize
  CopierHeaderSize = 512
  WramOffset = 0x7E0000
  WramSize = 0x20000
  SramSize = 0x2000
  FramesPerSecond = 60.0
  BgModeRegister = 0x05
  BgModeMask = 0x07
  DualScreenOption = "decompbound_dual_screen"
  DualScreenDescription = "EarthBound DS companion (restart required); disabled|enabled"
  Version = (if BuildCommit.len > 0: BuildCommit else: "unknown") &
    (if BuildDirty: "+dirty" else: "")

var
  environment: RetroEnvironment
  video: RetroVideoRefresh
  audio: RetroAudioSample
  audioBatch: RetroAudioSampleBatch
  inputPoll: RetroInputPoll
  inputState: RetroInputState
  logger: RetroLog
  machine: SnesBus
  cpuState: Cpu
  frameImage: Image
  pixels: seq[uint32]
  dualScreen: bool
  companion: DsCompanion
  pcm: FramePcm
  device = RetroDeviceJoypad

proc logError(message: string) =
  ## Send an error to the frontend when its logging interface is available.
  if logger != nil:
    logger(RetroLogError, "%s", message.cstring)

proc shutdown(message: string) =
  ## Report a frame or reset failure and request frontend shutdown.
  logError(message)
  if environment != nil:
    discard environment(RetroEnvShutdown, nil)

proc releaseHooks(snes: SnesBus) =
  ## Break emulator closure cycles before discarding an emulator instance.
  if snes == nil: return
  if snes.bus != nil:
    snes.bus.readHook = nil
    snes.bus.writeHook = nil
  if snes.apu != nil:
    snes.apu.spc.readHook = nil
    snes.apu.spc.writeHook = nil

proc releaseMachine() =
  ## Release the loaded machine and all presentation storage.
  releaseHooks(machine)
  machine = nil
  frameImage = nil
  companion = nil
  pixels.setLen(0)
  dualScreen = false
  GC_fullCollect()

proc retro_api_version(): cuint {.cdecl, exportc, dynlib.} =
  ## Return the supported libretro interface version.
  RetroApiVersion

proc retro_set_environment(callback: RetroEnvironment) {.cdecl, exportc, dynlib.} =
  ## Store the frontend environment callback.
  environment = callback
  if environment != nil:
    var variables = [RetroVariable(key: DualScreenOption, value: DualScreenDescription),
      RetroVariable()]
    discard environment(RetroEnvSetVariables, addr variables[0])

proc retro_set_video_refresh(callback: RetroVideoRefresh) {.cdecl, exportc, dynlib.} =
  ## Store the frontend video callback.
  video = callback

proc retro_set_audio_sample(callback: RetroAudioSample) {.cdecl, exportc, dynlib.} =
  ## Store the frontend single-sample callback.
  audio = callback

proc retro_set_audio_sample_batch(callback: RetroAudioSampleBatch) {.cdecl, exportc, dynlib.} =
  ## Store the frontend batch-audio callback.
  audioBatch = callback

proc retro_set_input_poll(callback: RetroInputPoll) {.cdecl, exportc, dynlib.} =
  ## Store the frontend input-poll callback.
  inputPoll = callback

proc retro_set_input_state(callback: RetroInputState) {.cdecl, exportc, dynlib.} =
  ## Store the frontend input-state callback.
  inputState = callback

proc retro_init() {.cdecl, exportc, dynlib.} =
  ## Initialize optional frontend logging.
  device = RetroDeviceJoypad
  logger = nil
  if environment != nil:
    var callback: RetroLogCallback
    if environment(RetroEnvGetLogInterface, addr callback):
      logger = callback.log

proc retro_deinit() {.cdecl, exportc, dynlib.} =
  ## Release machine resources before the frontend unloads the library.
  writeCoreProfile()
  clearCoreProfile()
  releaseMachine()
  logger = nil

proc retro_get_system_info(info: ptr RetroSystemInfo) {.cdecl, exportc, dynlib.} =
  ## Describe the supported ROM and core build.
  if info != nil:
    info[] = RetroSystemInfo(libraryName: "Decompbound", libraryVersion: Version.cstring,
      validExtensions: "smc|sfc", needFullpath: false, blockExtract: false)

proc retro_get_system_av_info(info: ptr RetroSystemAvInfo) {.cdecl, exportc, dynlib.} =
  ## Describe the fixed video and audio timing.
  if info != nil:
    info[] = RetroSystemAvInfo(
      geometry: RetroGameGeometry(baseWidth: Width,
        baseHeight: (if dualScreen: DsCombinedHeight.cuint else: Height.cuint),
        maxWidth: Width, maxHeight: (if dualScreen: DsCombinedHeight.cuint else: Height.cuint),
        aspectRatio: (if dualScreen: Width.float32 / DsCombinedHeight.float32 else: 8.0 / 7.0)),
      timing: RetroSystemTiming(fps: FramesPerSecond,
        sampleRate: FramesPerSecond * ApuSamplesPerFrame.float))

proc retro_set_controller_port_device(port, kind: cuint) {.cdecl, exportc, dynlib.} =
  ## Select the first controller or disconnect it.
  if port == 0:
    device = kind

proc retro_reset() {.cdecl, exportc, dynlib.} =
  ## Reset the loaded machine while preserving its memory.
  if machine != nil:
    try:
      # softReset replaces the APU, so sever its self-referential hooks first.
      if machine.apu != nil:
        machine.apu.spc.readHook = nil
        machine.apu.spc.writeHook = nil
      cpuState = machine.softReset()
      if dualScreen: companion = newDsCompanion(machine.rom)
      GC_fullCollect()
    except CatchableError as error:
      shutdown("Reset failed: " & error.msg)

proc retro_run() {.cdecl, exportc, dynlib.} =
  ## Poll input and submit one video frame and 533 stereo samples.
  if machine == nil:
    return
  beginCoreProfile()
  try:
    if inputPoll != nil:
      profileStage(InputCallback): inputPoll()
    machine.joy1 = 0
    if device == RetroDeviceJoypad and inputState != nil:
      for id in 0.cuint .. 11.cuint:
        var pressed: bool
        profileStage(InputCallback): pressed = inputState(0, RetroDeviceJoypad, 0, id) != 0
        if pressed:
          machine.joy1 = machine.joy1 or (1'u16 shl (15 - id.int))
    frameImage.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(machine, cpuState, frameImage, addr pcm)
    if dualScreen:
      var
        buttons: uint16
        pointerInput: DsPointer
      if inputState != nil:
        profileStage(InputCallback):
          if device == RetroDeviceJoypad:
            if inputState(0, RetroDeviceJoypad, 0, 12) != 0: buttons = buttons or PreviousMember
            if inputState(0, RetroDeviceJoypad, 0, 13) != 0: buttons = buttons or NextMember
          pointerInput = DsPointer(x: inputState(0, RetroDevicePointer, 0, 0),
            y: inputState(0, RetroDevicePointer, 0, 1),
            pressed: inputState(0, RetroDevicePointer, 0, 2) != 0)
      profileStage(Companion):
        companion.update(machine.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
          buttons, pointerInput,
          partyBattleVisible(machine.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
            (machine.ppuRegs[BgModeRegister] and BgModeMask).int),
          machine.cgram.toOpenArray(0, 31))
    if video != nil:
      profileStage(PixelPacking):
        for i in 0 ..< frameImage.data.len:
          let color = frameImage.data[i]
          pixels[i] = (color.r.uint32 shl 16) or (color.g.uint32 shl 8) or color.b.uint32
        if dualScreen:
          for i, color in companion.image.data:
            pixels[Width * Height + i] = (color.r.uint32 shl 16) or
              (color.g.uint32 shl 8) or color.b.uint32
      profileStage(VideoCallback):
        video(addr pixels[0], Width, (if dualScreen: DsCombinedHeight.cuint else: Height.cuint),
          Width * sizeof(uint32))
    if audioBatch != nil:
      profileStage(AudioCallback): discard audioBatch(addr pcm[0], ApuSamplesPerFrame)
    elif audio != nil:
      profileStage(AudioCallback):
        for i in 0 ..< ApuSamplesPerFrame:
          audio(pcm[i * 2], pcm[i * 2 + 1])
  except CatchableError as error:
    shutdown("Frame failed: " & error.msg)
  finally:
    endCoreProfile()

proc retro_serialize_size(): csize_t {.cdecl, exportc, dynlib.} =
  ## Indicate that state creation is unsupported; explicit imports are accepted separately.
  0

proc retro_serialize(data: pointer, size: csize_t): bool {.cdecl, exportc, dynlib.} =
  ## Decline save-state serialization.
  false

proc retro_unserialize(data: pointer, size: csize_t): bool {.cdecl, exportc, dynlib.} =
  ## Import a DBST blob or ROM-matched state PNG without changing live memory on rejection.
  if machine == nil or data == nil or size == 0 or size > MaxStateBytes.csize_t:
    logError("State import requires loaded content and a nonempty state of at most 64 MiB.")
    return false
  var staged: SnesBus
  try:
    var bytes = newSeq[uint8](size.int)
    copyMem(addr bytes[0], data, size.int)
    if bytes.len >= PngSignature.len and bytes[0 ..< PngSignature.len] == @PngSignature:
      bytes = extractStateForRom(bytes, romHashOf(machine.rom))
    staged = newSnesBus(machine.rom)
    var stagedCpu: Cpu
    deserializeState(bytes, staged, stagedCpu)
    deserializeState(bytes, machine, cpuState)
    if dualScreen: companion = newDsCompanion(machine.rom)
    frameImage.fill(rgbx(0, 0, 0, 255))
    pcm = default(FramePcm)
    result = true
  except CatchableError as error:
    logError("State import failed: " & error.msg)
  finally:
    releaseHooks(staged)
    staged = nil
    GC_fullCollect()

proc retro_cheat_reset() {.cdecl, exportc, dynlib.} =
  ## Ignore unsupported cheats.
  discard

proc retro_cheat_set(index: cuint, enabled: bool, code: cstring) {.cdecl, exportc, dynlib.} =
  ## Ignore an unsupported cheat.
  discard

proc retro_load_game(info: ptr RetroGameInfo): bool {.cdecl, exportc, dynlib.} =
  ## Copy and load a headered or unheadered EarthBound ROM.
  if info == nil or info.data == nil or
      (info.size != RomSize.csize_t and info.size != (RomSize + CopierHeaderSize).csize_t):
    logError("Expected a 3 MiB ROM, optionally with a 512-byte copier header.")
    return false
  if environment == nil:
    logError("Frontend environment callback is unavailable.")
    return false
  var format = RetroPixelFormatXrgb8888
  if not environment(RetroEnvSetPixelFormat, addr format):
    logError("Frontend does not support XRGB8888 video.")
    return false
  try:
    releaseMachine()
    var setting = RetroVariable(key: DualScreenOption)
    dualScreen = environment(RetroEnvGetVariable, addr setting) and
      setting.value != nil and $setting.value == "enabled"
    let offset = if info.size == RomSize.csize_t: 0 else: CopierHeaderSize
    var rom = newSeq[uint8](RomSize)
    copyMem(addr rom[0], cast[pointer](cast[uint](info.data) + offset.uint), RomSize)
    machine = newSnesBus(rom)
    cpuState = machine.resetCpu()
    frameImage = newImage(Width, Height)
    pixels = newSeq[uint32](Width * (if dualScreen: DsCombinedHeight else: Height))
    if dualScreen: companion = newDsCompanion(rom)
    resetCoreProfile()
    result = true
  except CatchableError as error:
    releaseMachine()
    logError("Load failed: " & error.msg)
    result = false

proc retro_load_game_special(gameType: cuint, info: ptr RetroGameInfo,
    count: csize_t): bool {.cdecl, exportc, dynlib.} =
  ## Decline unsupported multi-game content.
  false

proc retro_unload_game() {.cdecl, exportc, dynlib.} =
  ## Release loaded game resources.
  writeCoreProfile()
  releaseMachine()

proc retro_get_region(): cuint {.cdecl, exportc, dynlib.} =
  ## Return the NTSC timing region.
  RetroRegionNtsc

proc retro_get_memory_data(id: cuint): pointer {.cdecl, exportc, dynlib.} =
  ## Expose stable SRAM or WRAM owned by the loaded machine.
  if machine != nil:
    case id
    of RetroMemorySaveRam: result = addr machine.sram[0]
    of RetroMemorySystemRam: result = addr machine.bus.mem[WramOffset]
    else: discard

proc retro_get_memory_size(id: cuint): csize_t {.cdecl, exportc, dynlib.} =
  ## Return the size of an exposed memory region.
  if machine != nil:
    case id
    of RetroMemorySaveRam: result = SramSize
    of RetroMemorySystemRam: result = WramSize
    else: discard
