## A single-instance libretro adapter around the headless SNES emulator.

import
  pixie,
  ../decompbound/[apu, build_info, common, core_profile, cpu, cpu_polling, ds_companion,
    expanded_viewport, frame_step, libretro_api, png_state, ppu, replay_run, save_state,
    snesbus, viewport_geometry]

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
  OpaqueBlack = 0xFF000000'u32
    ## XB24 stores opaque black as R,G,B,255 on the negotiated little-endian transport.
  DualScreenOption = "decompbound_dual_screen"
  DualScreenDescription = "EarthBound DS companion (restart required); disabled|enabled"
  StatePayloadLengthBytes = 4
    ## Little-endian DBST length trailer at the end of the fixed libretro envelope.
  Version = (if BuildCommit.len > 0: BuildCommit else: "unknown") &
    (if BuildDirty: "+dirty" else: "")

let
  widthDescription = dimensionOptions("Experimental viewport width", OriginalWidth)
  heightDescription = dimensionOptions("Experimental viewport height", OriginalHeight)

var
  environment: RetroEnvironment
  video: RetroVideoRefresh
  audio: RetroAudioSample
  audioBatch: RetroAudioSampleBatch
  inputPoll: RetroInputPoll
  inputState: RetroInputState
  logger: RetroLog
  machine: SnesBus
  polling: CpuPollingContext
  cpuState: Cpu
  frameImage: Image
  pixels: seq[uint32]
  geometry = viewportGeometry()
  expandedView: ExpandedViewport
  visibleHook: VisibleFrameHook
  scanlineHook: ScanlineHook
  presentationDescription: string
  dualScreen: bool
  opaquePixieVideo: bool
  companion: DsCompanion
  pcm: FramePcm
  device = RetroDeviceJoypad

proc logError(message: string) =
  ## Send an error to the frontend when its logging interface is available.
  if logger != nil:
    logger(RetroLogError, "%s", message.cstring)

proc logVideoTransport() =
  ## Announce the selected transport once after each successful content load.
  let message = if opaquePixieVideo:
    "Video transport: private opaque XBGR8888 (R,G,B,255)."
  else:
    "Video transport: standard XRGB8888."
  if logger != nil:
    logger(RetroLogInfo, "%s", message.cstring)
  else:
    stderr.writeLine("Decompbound: " & message)

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
  polling = nil
  releaseHooks(machine)
  machine = nil
  frameImage = nil
  companion = nil
  pixels.setLen(0)
  dualScreen = false
  opaquePixieVideo = false
  expandedView = nil
  visibleHook = nil
  scanlineHook = nil
  geometry = viewportGeometry()
  presentationDescription = ""
  GC_fullCollect()

proc resetPresentation() =
  ## Recreate read-only scene resources after a machine discontinuity.
  expandedView = nil
  visibleHook = nil
  scanlineHook = nil
  presentationDescription = ""
  if geometry.expanded:
    expandedView = newExpandedViewport(machine.rom, geometry.width, geometry.height)
    visibleHook = proc(snes: SnesBus) =
      ## Sample the scene before next-frame NMI uploads.
      profileStage(ExpandedScenery): expandedView.capture(snes)
    scanlineHook = proc(snes: SnesBus, line: int) =
      ## Preserve the actual row's HDMA phase and palette without advancing the game.
      profileStage(ExpandedScenery): expandedView.captureScanline(snes, line)

proc readDimension(key: cstring, fallback: int): int =
  ## Read a startup-only option, preserving defaults on older frontends.
  var setting = RetroVariable(key: key)
  result = fallback
  if environment(RetroEnvGetVariable, addr setting) and setting.value != nil:
    result = parseDimension($setting.value, fallback)

proc retro_api_version(): cuint {.cdecl, exportc, dynlib.} =
  ## Return the supported libretro interface version.
  RetroApiVersion

proc retro_set_environment(callback: RetroEnvironment) {.cdecl, exportc, dynlib.} =
  ## Store the frontend environment callback.
  environment = callback
  if environment != nil:
    var variables = [RetroVariable(key: DualScreenOption, value: DualScreenDescription),
      RetroVariable(key: ViewportWidthOption, value: widthDescription.cstring),
      RetroVariable(key: ViewportHeightOption, value: heightDescription.cstring),
      RetroVariable()]
    discard environment(RetroEnvSetVariables, addr variables[0])
    var supportsAchievements = true
    discard environment(RetroEnvSetSupportAchievements, addr supportsAchievements)

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
  ## Describe the selected startup geometry and fixed audio timing.
  if info != nil:
    info[] = RetroSystemAvInfo(
      geometry: RetroGameGeometry(baseWidth: geometry.width.cuint,
        baseHeight: geometry.outputHeight(dualScreen).cuint,
        maxWidth: geometry.width.cuint, maxHeight: geometry.outputHeight(dualScreen).cuint,
        aspectRatio: geometry.width.float32 / geometry.outputHeight(dualScreen).float32),
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
      resetPresentation()
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
    stepReplayFrame(machine, cpuState, frameImage, addr pcm, polling, visibleHook, scanlineHook)
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
        if geometry.expanded: pointerInput = geometry.companionPointer(pointerInput)
        companion.update(machine.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
          buttons, pointerInput,
          partyBattleVisible(machine.bus.mem.toOpenArray(WramOffset, WramOffset + WramSize - 1),
            (machine.ppuRegs[BgModeRegister] and BgModeMask).int),
          machine.cgram.toOpenArray(0, 31))
    if video != nil:
      profileStage(PixelPacking):
        var gameImage = frameImage
        if expandedView != nil:
          profileStage(ExpandedScenery): gameImage = expandedView.compose(frameImage)
        if expandedView != nil and expandedView.presentation != presentationDescription:
          presentationDescription = expandedView.presentation
          let message = "Viewport " & $geometry.width & "x" & $geometry.height & ": " & presentationDescription
          if logger != nil: logger(RetroLogInfo, "%s", message.cstring)
          else: stderr.writeLine("Decompbound: " & message)
        template pack(image: Image, left, top: int) =
          if opaquePixieVideo and image.width == geometry.width:
            static: doAssert sizeof(ColorRGBX) == sizeof(uint32)
            copyMem(addr pixels[top * geometry.width], unsafeAddr image.data[0],
              image.data.len * sizeof(ColorRGBX))
          else:
            for row in 0 ..< image.height:
              let destination = (top + row) * geometry.width + left
              if opaquePixieVideo:
                copyMem(addr pixels[destination], unsafeAddr image.data[row * image.width],
                  image.width * sizeof(ColorRGBX))
              else:
                for column in 0 ..< image.width:
                  let color = image.data[row * image.width + column]
                  pixels[destination + column] = (color.r.uint32 shl 16) or
                    (color.g.uint32 shl 8) or color.b.uint32
        pack(gameImage, 0, 0)
        if dualScreen:
          pack(companion.image, (geometry.width - Width) div 2, geometry.height)
      profileStage(VideoCallback):
        video(addr pixels[0], geometry.width.cuint, geometry.outputHeight(dualScreen).cuint,
          (geometry.width * sizeof(uint32)).csize_t)
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

proc copyBytes(data: pointer, size: int): seq[uint8] =
  ## Copy `size` bytes from a frontend buffer into an owned sequence.
  result = newSeq[uint8](size)
  if size > 0:
    copyMem(addr result[0], data, size)

proc writeU32leAt(data: pointer, offset: int, value: uint32) =
  ## Store a little-endian word at `offset` in a frontend buffer.
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  bytes[offset] = uint8(value and 0xFF)
  bytes[offset + 1] = uint8((value shr 8) and 0xFF)
  bytes[offset + 2] = uint8((value shr 16) and 0xFF)
  bytes[offset + 3] = uint8((value shr 24) and 0xFF)

proc readU32leAt(data: pointer, offset: int): uint32 =
  ## Load a little-endian word at `offset` from a frontend buffer.
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  bytes[offset].uint32 or (bytes[offset + 1].uint32 shl 8) or
    (bytes[offset + 2].uint32 shl 16) or (bytes[offset + 3].uint32 shl 24)

proc startsWithPng(data: pointer, size: csize_t): bool =
  ## True when the frontend buffer begins with a PNG signature.
  if size < PngSignature.len.csize_t:
    return false
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  result = true
  for i, expected in PngSignature:
    if bytes[i] != expected:
      return false

proc envelopePayloadLength(data: pointer, size: csize_t): int =
  ## Return the DBST length stored in a fixed-size export envelope, or 0.
  ## serializeState grows with apuPostBoot/apuJumps, so libretro export uses a
  ## stable MaxStateBytes envelope: DBST payload, zero padding, length trailer.
  if size != MaxStateBytes.csize_t:
    return 0
  let
    bytes = cast[ptr UncheckedArray[uint8]](data)
    payload = readU32leAt(data, size.int - StatePayloadLengthBytes).int
    paddingEnd = size.int - StatePayloadLengthBytes
  if payload < 8 or payload > paddingEnd:
    return 0
  for index, expected in StateMagic:
    if bytes[index] != expected.uint8: return 0
  for i in payload ..< paddingEnd:
    if bytes[i] != 0:
      return 0
  payload

proc retro_serialize_size(): csize_t {.cdecl, exportc, dynlib.} =
  ## Return the fixed export envelope size, or zero when no machine is loaded.
  ## The size is the existing MaxStateBytes import ceiling so it cannot move
  ## with live APU port/jump logs inside serializeState.
  if machine != nil:
    result = MaxStateBytes.csize_t

proc retro_serialize(data: pointer, size: csize_t): bool {.cdecl, exportc, dynlib.} =
  ## Write serializeState into a zero-padded MaxStateBytes envelope.
  if machine == nil or data == nil or size < MaxStateBytes.csize_t:
    return false
  try:
    let payload = serializeState(machine, cpuState)
    if payload.len + StatePayloadLengthBytes > MaxStateBytes:
      logError("State export exceeds the 64 MiB libretro envelope.")
      return false
    if payload.len > 0:
      copyMem(data, addr payload[0], payload.len)
    let paddingEnd = MaxStateBytes - StatePayloadLengthBytes
    if paddingEnd > payload.len:
      zeroMem(cast[pointer](cast[uint](data) + payload.len.uint),
        paddingEnd - payload.len)
    writeU32leAt(data, paddingEnd, payload.len.uint32)
    result = true
  except CatchableError as error:
    logError("State export failed: " & error.msg)

proc retro_unserialize(data: pointer, size: csize_t): bool {.cdecl, exportc, dynlib.} =
  ## Import a DBST blob, padded export envelope, or ROM-matched state PNG.
  ## Rejection leaves live memory unchanged. Exceptions never escape the C ABI.
  if machine == nil or data == nil or size == 0 or size > MaxStateBytes.csize_t:
    logError("State import requires loaded content and a nonempty state of at most 64 MiB.")
    return false
  var staged: SnesBus
  try:
    var bytes: seq[uint8]
    if startsWithPng(data, size):
      bytes = copyBytes(data, size.int)
      bytes = extractStateForRom(bytes, romHashOf(machine.rom))
      if bytes.len > 0:
        let payloadLen = envelopePayloadLength(unsafeAddr bytes[0], bytes.len.csize_t)
        if payloadLen > 0: bytes.setLen(payloadLen)
    else:
      let payloadLen = envelopePayloadLength(data, size)
      if payloadLen > 0:
        bytes = copyBytes(data, payloadLen)
      else:
        bytes = copyBytes(data, size.int)
    staged = newSnesBus(machine.rom)
    var stagedCpu: Cpu
    deserializeState(bytes, staged, stagedCpu)
    deserializeState(bytes, machine, cpuState)
    if dualScreen: companion = newDsCompanion(machine.rom)
    resetPresentation()
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
  var privateFormat = MonoRetroPixelFormatXbgr8888
  let useOpaquePixie = environment(MonoRetroEnvSetPixelFormat, addr privateFormat)
  if not useOpaquePixie:
    var format = RetroPixelFormatXrgb8888
    if not environment(RetroEnvSetPixelFormat, addr format):
      logError("Frontend does not support private XBGR8888 or standard XRGB8888 video.")
      return false
  try:
    releaseMachine()
    opaquePixieVideo = useOpaquePixie
    var setting = RetroVariable(key: DualScreenOption)
    dualScreen = environment(RetroEnvGetVariable, addr setting) and
      setting.value != nil and $setting.value == "enabled"
    geometry = viewportGeometry(readDimension(ViewportWidthOption, Width),
      readDimension(ViewportHeightOption, Height))
    let offset = if info.size == RomSize.csize_t: 0 else: CopierHeaderSize
    var rom = newSeq[uint8](RomSize)
    copyMem(addr rom[0], cast[pointer](cast[uint](info.data) + offset.uint), RomSize)
    when defined(disableCpuPollingBatching):
      machine = newSnesBus(rom)
    else:
      (machine, polling) = newPollingMachine(rom)
    cpuState = machine.resetCpu()
    frameImage = newImage(Width, Height)
    pixels = newSeq[uint32](geometry.width * geometry.outputHeight(dualScreen))
    if opaquePixieVideo:
      for pixel in pixels.mitems: pixel = OpaqueBlack
    if dualScreen: companion = newDsCompanion(rom)
    resetPresentation()
    resetCoreProfile()
    logVideoTransport()
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
