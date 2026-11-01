import
  std/[dynlib, os, posix, strutils],
  ../../src/decompbound/[frame_step, libretro_api, rom_pipeline, viewport_geometry]

const WalkPeriodFrames = 30

type
  VoidProc = proc() {.cdecl.}
  LoadGame = proc(info: ptr RetroGameInfo): bool {.cdecl.}
  StateTransfer = proc(data: pointer, size: csize_t): bool {.cdecl.}
  StateSize = proc(): csize_t {.cdecl.}
  SetEnvironment = proc(callback: RetroEnvironment) {.cdecl.}
  SetVideo = proc(callback: RetroVideoRefresh) {.cdecl.}
  SetAudio = proc(callback: RetroAudioSampleBatch) {.cdecl.}
  SetPoll = proc(callback: RetroInputPoll) {.cdecl.}
  SetInput = proc(callback: RetroInputState) {.cdecl.}

var
  protocolOutput: File
  widthValue, heightValue: string
  dualScreen, opaque, walking: bool
  frame, polls, videoCalls: int
  videoWidth, videoHeight, videoPitch: uint64
  pixels, pcm: seq[uint8]
  callbackFailure: string

proc symbol[T](library: LibHandle, name: string): T =
  ## Resolve a required public libretro entry point.
  let address = symAddr(library, name)
  if address == nil: raise newException(IOError, "Missing core symbol: " & name)
  cast[T](address)

proc writeBlock(data: pointer, size: int) =
  ## Stream complete buffers to the exact-byte referee without writing game data to disk.
  protocolOutput.writeLine(size)
  if size > 0 and protocolOutput.writeBuffer(data, size) != size:
    raise newException(IOError, "Short core comparison write")

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Negotiate each requested transport and geometry through the real core ABI.
  case command
  of MonoRetroEnvSetPixelFormat:
    result = opaque and data != nil and
      cast[ptr uint32](data)[] == MonoRetroPixelFormatXbgr8888
  of RetroEnvSetPixelFormat:
    result = data != nil and cast[ptr cuint](data)[] == RetroPixelFormatXrgb8888
  of RetroEnvSetVariables:
    result = true
  of RetroEnvGetVariable:
    if data != nil:
      let setting = cast[ptr RetroVariable](data)
      case $setting.key
      of "decompbound_dual_screen":
        setting.value = if dualScreen: "enabled" else: "disabled"
        result = true
      of ViewportWidthOption:
        setting.value = widthValue.cstring
        result = true
      of ViewportHeightOption:
        setting.value = heightValue.cstring
        result = true
  of RetroEnvShutdown:
    callbackFailure = "Core requested shutdown"
    result = true
  else: discard

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Copy delivered pixels immediately so later frames cannot alter the evidence.
  inc videoCalls
  if data == nil or pitch != width.csize_t * sizeof(uint32).csize_t:
    callbackFailure = "Core delivered missing pixels or an unexpected pitch"
    return
  videoWidth = width.uint64
  videoHeight = height.uint64
  videoPitch = pitch.uint64
  pixels.setLen(height.int * pitch.int)
  if pixels.len > 0: copyMem(addr pixels[0], data, pixels.len)
  if opaque:
    for offset in countup(3, pixels.high, sizeof(uint32)):
      if pixels[offset] != 255:
        callbackFailure = "Opaque transport delivered nonopaque filler"

proc audio(data: ptr int16, frames: csize_t): csize_t {.cdecl.} =
  ## Capture stereo PCM solely in memory, without an audio backend.
  let start = pcm.len
  pcm.setLen(start + frames.int * 2 * sizeof(int16))
  if pcm.len > start: copyMem(addr pcm[start], data, pcm.len - start)
  frames

proc poll() {.cdecl.} =
  ## Count input polls for comparison alongside pixels and emulated state.
  inc polls

proc input(port, device, index, id: cuint): int16 {.cdecl.} =
  ## Optionally drive the same deterministic alternating walk as the profile host.
  if walking and port == 0 and device == RetroDeviceJoypad and index == 0:
    let held = if (frame div WalkPeriodFrames) mod 2 == 0: 7.cuint else: 6.cuint
    if id == held: result = 1

proc capture(path: string, library: LibHandle, state: var seq[uint8], frames: int) =
  ## Restore a private capture and compare actual shared-library frame output and state payloads.
  var bytes = cast[seq[uint8]](readFile(path))
  callbackFailure.setLen(0)
  if not symbol[StateTransfer](library, "retro_unserialize")(addr bytes[0], bytes.len.csize_t):
    protocolOutput.writeLine("INCOMPATIBLE core rejected state")
    protocolOutput.flushFile()
    return
  protocolOutput.writeLine("OK")
  for current in 0..<frames:
    frame = current
    polls = 0
    videoCalls = 0
    pcm.setLen(0)
    symbol[VoidProc](library, "retro_run")()
    if callbackFailure.len > 0: raise newException(IOError, callbackFailure)
    if videoCalls != 1 or polls < 1 or pcm.len != ApuSamplesPerFrame * 2 * sizeof(int16):
      raise newException(IOError, "Unexpected core callback counts")
    if not symbol[StateTransfer](library, "retro_serialize")(addr state[0], state.len.csize_t):
      raise newException(IOError, "Core state export failed")
    let
      trailer = state.len - sizeof(uint32)
      length = state[trailer].int or (state[trailer + 1].int shl 8) or
        (state[trailer + 2].int shl 16) or (state[trailer + 3].int shl 24)
    if length < 8 or length > trailer:
      raise newException(IOError, "Invalid serialized payload length")
    var dimensions = [videoWidth, videoHeight, videoPitch, polls.uint64, state.len.uint64]
    writeBlock(addr pixels[0], pixels.len)
    writeBlock(addr pcm[0], pcm.len)
    writeBlock(addr state[0], length)
    writeBlock(addr dimensions[0], sizeof(dimensions))
  protocolOutput.flushFile()

proc main() =
  ## Run one isolated shared-library worker using the existing corpus pipe protocol.
  if paramCount() != 2:
    raise newException(ValueError, "libretro_worker ROM DIAGNOSTICS; set LIBRETRO_CORPUS_CORE")
  let diagnostics = open(paramStr(2), fmWrite)
  defer: diagnostics.close()
  let output = dup(STDOUT_FILENO)
  if output < 0 or not protocolOutput.open(FileHandle(output), fmWrite):
    raise newException(IOError, "Cannot preserve comparison output pipe")
  defer: protocolOutput.close()
  if dup2(getFileHandle(diagnostics).cint, STDOUT_FILENO) < 0 or
      dup2(getFileHandle(diagnostics).cint, STDERR_FILENO) < 0:
    raise newException(IOError, "Cannot redirect core diagnostics")
  widthValue = getEnv("VIEWPORT_PARITY_WIDTH", "336")
  heightValue = getEnv("VIEWPORT_PARITY_HEIGHT", "256")
  dualScreen = getEnv("LIBRETRO_CORPUS_DS", "1") == "1"
  opaque = getEnv("LIBRETRO_CORPUS_XBGR", "1") == "1"
  walking = getEnv("LIBRETRO_CORPUS_WALK", "0") == "1"
  let
    frames = parseInt(getEnv("PPU_CORPUS_FRAMES", "3"))
    library = loadLib(getEnv("LIBRETRO_CORPUS_CORE"))
  if frames notin 1..3600 or library == nil:
    raise newException(ValueError, "Invalid frame count or missing comparison core")
  defer: unloadLib(library)
  symbol[SetEnvironment](library, "retro_set_environment")(environment)
  symbol[SetVideo](library, "retro_set_video_refresh")(video)
  symbol[SetAudio](library, "retro_set_audio_sample_batch")(audio)
  symbol[SetPoll](library, "retro_set_input_poll")(poll)
  symbol[SetInput](library, "retro_set_input_state")(input)
  symbol[VoidProc](library, "retro_init")()
  defer: symbol[VoidProc](library, "retro_deinit")()
  var
    rom = readGoldBaserom(paramStr(1))
    game = RetroGameInfo(data: addr rom[0], size: rom.len.csize_t)
  if not symbol[LoadGame](library, "retro_load_game")(addr game):
    raise newException(IOError, "Core rejected ROM")
  defer: symbol[VoidProc](library, "retro_unload_game")()
  var
    state = newSeq[uint8](symbol[StateSize](library, "retro_serialize_size")().int)
    path: string
  if state.len <= sizeof(uint32): raise newException(IOError, "Invalid core export envelope")
  while stdin.readLine(path):
    if path.len == 0: break
    capture(path, library, state, frames)

main()
