## Profile the actual libretro shared library without display/audio devices or saves.
## All output is numeric evidence and metadata; game buffers remain in memory.

import
  std/[algorithm, dynlib, json, monotimes, os, parseopt, strutils],
  ../decompbound/libretro_api

when defined(linux):
  import std/posix

const
  DefaultFrames = 600
  DefaultWarmup = 120
  WalkPeriod = 30
  JoypadLeft = 6.cuint
  JoypadRight = 7.cuint
  NanosecondsPerSecond = 1_000_000_000'i64
  Usage = "libretro_profile --core:PATH --rom:PATH [--state:PATH] " &
    "[--frames:N] [--warmup:N] [--ds] [--walk] [--hash] [--xbgr] --out:bin/NAME.json"
  CrcPolynomial = 0xEDB88320'u32
  CrcInitial = 0xFFFFFFFF'u32

type
  Options = object
    corePath, romPath, statePath, outPath: string
    frames, warmup: int
    dualScreen, walk, hash, xbgr: bool
  VoidProc = proc() {.cdecl.}
  ApiVersion = proc(): cuint {.cdecl.}
  SystemInfo = proc(info: ptr RetroSystemInfo) {.cdecl.}
  LoadGame = proc(info: ptr RetroGameInfo): bool {.cdecl.}
  Unserialize = proc(data: pointer, size: csize_t): bool {.cdecl.}
  MemoryData = proc(id: cuint): pointer {.cdecl.}
  MemorySize = proc(id: cuint): csize_t {.cdecl.}
  SetEnvironment = proc(callback: RetroEnvironment) {.cdecl.}
  SetVideo = proc(callback: RetroVideoRefresh) {.cdecl.}
  SetAudio = proc(callback: RetroAudioSample) {.cdecl.}
  SetBatch = proc(callback: RetroAudioSampleBatch) {.cdecl.}
  SetPoll = proc(callback: RetroInputPoll) {.cdecl.}
  SetInput = proc(callback: RetroInputState) {.cdecl.}
  CallbackState = object
    dualScreen, walk, hashing, offerOpaque, opaqueAccepted: bool
    frame: int
    failure: string
    videoCalls, audioFrames, pollCalls, videoBytes: int64
    width, height: cuint
    pitch: csize_t
    videoCrc, audioCrc: uint32

func makeCrcTable(): array[256, uint32] =
  ## Build the standard reflected CRC32 lookup table without dependencies.
  for index in 0 ..< result.len:
    var value = index.uint32
    for bit in 0 ..< 8:
      value = if (value and 1) != 0: (value shr 1) xor CrcPolynomial else: value shr 1
    result[index] = value

const CrcTable = makeCrcTable()

var callbacks: CallbackState

proc updateCrc(crc: var uint32, data: pointer, size: int) =
  ## Fold bytes in their delivered order without allocating or copying buffers.
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  for index in 0 ..< size:
    crc = (crc shr 8) xor CrcTable[((crc xor bytes[index].uint32) and 255).int]

proc checkCallbacks() =
  ## Report callback failures after returning from the foreign ABI.
  if callbacks.failure.len > 0:
    raise newException(IOError, callbacks.failure)

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Negotiate the core's software pixel format and startup companion option.
  case command
  of MonoRetroEnvSetPixelFormat:
    result = cpuEndian == littleEndian and callbacks.offerOpaque and data != nil and
      cast[ptr uint32](data)[] == MonoRetroPixelFormatXbgr8888
    if result: callbacks.opaqueAccepted = true
  of RetroEnvSetPixelFormat:
    result = data != nil and cast[ptr cuint](data)[] == RetroPixelFormatXrgb8888
    if result: callbacks.opaqueAccepted = false
  of RetroEnvSetVariables:
    result = true
  of RetroEnvGetVariable:
    if data != nil:
      let setting = cast[ptr RetroVariable](data)
      if setting.key != nil and $setting.key == "decompbound_dual_screen":
        setting.value = if callbacks.dualScreen: "enabled" else: "disabled"
        result = true
  of RetroEnvShutdown:
    callbacks.failure = "The core requested shutdown."
    result = true
  else:
    discard

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Keep video packing active and optionally hash every delivered buffer byte.
  if data == nil or data == cast[pointer](high(uint)) or width == 0 or height == 0 or
      pitch < width.csize_t * 4 or pitch > high(int).csize_t div height.csize_t:
    callbacks.failure = "The core delivered invalid software video."
    return
  let size = pitch.int * height.int
  callbacks.width = width
  callbacks.height = height
  callbacks.pitch = pitch
  inc callbacks.videoCalls
  callbacks.videoBytes += size.int64
  if callbacks.hashing:
    updateCrc(callbacks.videoCrc, data, size)

proc sample(left, right: int16) {.cdecl.} =
  ## Consume a stereo sample without opening an audio backend.
  inc callbacks.audioFrames
  if callbacks.hashing:
    var stereo = [left, right]
    updateCrc(callbacks.audioCrc, addr stereo[0], sizeof(stereo))

proc batch(data: ptr int16, frames: csize_t): csize_t {.cdecl.} =
  ## Consume stereo PCM batches while preserving the adapter's normal audio path.
  if (data == nil and frames != 0) or frames > (high(int) div 4).csize_t:
    callbacks.failure = "The core delivered invalid stereo PCM."
    return 0
  callbacks.audioFrames += frames.int64
  if callbacks.hashing and frames != 0:
    updateCrc(callbacks.audioCrc, data, frames.int * 4)
  result = frames

proc poll() {.cdecl.} =
  ## Count the core's input snapshots without consulting physical devices.
  inc callbacks.pollCalls

proc input(port, device, index, id: cuint): int16 {.cdecl.} =
  ## Hold right/left alternately for thirty frames, or leave all input released.
  if callbacks.walk and port == 0 and device == RetroDeviceJoypad and index == 0:
    let direction = if (callbacks.frame div WalkPeriod) mod 2 == 0: JoypadRight else: JoypadLeft
    if id == direction:
      result = 1

proc symbol[T](library: LibHandle, name: string): T =
  ## Resolve a required ABI symbol before initializing the shared core.
  let address = symAddr(library, name)
  if address == nil:
    raise newException(IOError, "Missing libretro symbol: " & name)
  result = cast[T](address)

proc threadCpuNs(): int64 =
  ## Read Linux calling-thread CPU time; other platforms report unsupported.
  when defined(linux):
    var stamp: Timespec
    if clock_gettime(CLOCK_THREAD_CPUTIME_ID, stamp) != 0:
      raiseOSError(osLastError(), "CLOCK_THREAD_CPUTIME_ID failed")
    result = stamp.tv_sec.int64 * NanosecondsPerSecond + stamp.tv_nsec.int64
  else:
    result = 0

proc validateOutput(path: string): string =
  ## Restrict JSON artifacts to cwd/bin, rejecting symlink paths and input aliases.
  let
    root = absolutePath("bin")
    target = absolutePath(path)
    relative = relativePath(target, root)
  if path.len == 0 or target.splitFile.ext != ".json" or relative == "." or
      relative == ".." or relative.startsWith(".." & DirSep) or relative.isAbsolute:
    raise newException(ValueError, "--out must be a .json file beneath cwd/bin. " &
      "On a device, run inside an isolated scratch directory.")
  var ancestor = target
  while true:
    if symlinkExists(ancestor):
      raise newException(ValueError, "Output paths must not contain symlinks: " & ancestor)
    let parent = ancestor.parentDir
    if parent == ancestor or parent.len == 0:
      break
    ancestor = parent
  result = target

proc parseOptions(): Options =
  ## Parse explicit benchmark inputs and reject ambiguous or invalid options.
  result.frames = DefaultFrames
  result.warmup = DefaultWarmup
  var parser = initOptParser(commandLineParams())
  for kind, key, value in parser.getopt():
    if kind != cmdLongOption:
      raise newException(ValueError, "Expected long options. " & Usage)
    case key
    of "core": result.corePath = value
    of "rom": result.romPath = value
    of "state": result.statePath = value
    of "out": result.outPath = value
    of "frames": result.frames = parseInt(value)
    of "warmup": result.warmup = parseInt(value)
    of "ds", "walk", "hash", "xbgr":
      if value.len != 0:
        raise newException(ValueError, "--" & key & " takes no value.")
      case key
      of "ds": result.dualScreen = true
      of "walk": result.walk = true
      of "xbgr": result.xbgr = true
      else: result.hash = true
    of "help":
      echo Usage
      quit(0)
    else:
      raise newException(ValueError, "Unknown option --" & key & ". " & Usage)
  if result.corePath.len == 0 or result.romPath.len == 0 or result.outPath.len == 0:
    raise newException(ValueError, "--core, --rom and --out are required. " & Usage)
  if result.frames < 1 or result.warmup < 0 or result.warmup > high(int) - result.frames:
    raise newException(ValueError, "Frames must be positive and warmup nonnegative.")
  result.outPath = validateOutput(result.outPath)
  for path in [result.corePath, result.romPath, result.statePath]:
    if path.len > 0:
      if not fileExists(path):
        raise newException(IOError, "Input file does not exist: " & path)
      if expandFilename(path) == result.outPath:
        raise newException(ValueError, "Output must not overwrite an input file.")
  result.corePath = absolutePath(result.corePath)

proc statistics(values: seq[int64]): JsonNode =
  ## Summarize nanoseconds using nearest-rank p95/p99 and the exact middle median.
  var sorted = values
  sorted.sort()
  var total = 0.0
  for value in sorted:
    total += value.float64
  let
    count = sorted.len
    middle = count div 2
    median = if count mod 2 == 0:
      sorted[middle - 1].float64 / 2 + sorted[middle].float64 / 2
    else:
      sorted[middle].float64
    p95Index = count - 1 - (count div 20)
    p99Index = count - 1 - (count div 100)
  result = %*{
    "mean": total / count.float64,
    "median": median,
    "p95": sorted[p95Index],
    "p99": sorted[p99Index],
    "max": sorted[^1]
  }

proc memoryHash(library: LibHandle, id: cuint): JsonNode =
  ## Hash exposed final memory without serializing or persisting its contents.
  let
    size = symbol[MemorySize](library, "retro_get_memory_size")(id)
    data = symbol[MemoryData](library, "retro_get_memory_data")(id)
  if size > high(int).csize_t or (size != 0 and data == nil):
    raise newException(IOError, "Invalid libretro memory buffer for id " & $id)
  var crc = CrcInitial
  updateCrc(crc, data, size.int)
  result = %*{"bytes": size.int, "crc32": (crc xor CrcInitial).int64}

proc profile(options: Options): JsonNode =
  ## Run the shared core with non-nil output callbacks and no SRAM persistence.
  let library = loadLib(options.corePath)
  if library == nil:
    raise newException(IOError, "Cannot load shared core: " & options.corePath)
  defer: unloadLib(library)
  let
    init = symbol[VoidProc](library, "retro_init")
    deinit = symbol[VoidProc](library, "retro_deinit")
    loadGame = symbol[LoadGame](library, "retro_load_game")
    unloadGame = symbol[VoidProc](library, "retro_unload_game")
    run = symbol[VoidProc](library, "retro_run")
    unserialize = symbol[Unserialize](library, "retro_unserialize")
    rom = readFile(options.romPath)
  if rom.len == 0:
    raise newException(ValueError, "The ROM is empty.")
  if symbol[ApiVersion](library, "retro_api_version")() != RetroApiVersion:
    raise newException(IOError, "Unsupported libretro API version.")
  var info: RetroSystemInfo
  symbol[SystemInfo](library, "retro_get_system_info")(addr info)
  callbacks = CallbackState(dualScreen: options.dualScreen, walk: options.walk,
    offerOpaque: options.xbgr,
    videoCrc: CrcInitial, audioCrc: CrcInitial)
  symbol[SetEnvironment](library, "retro_set_environment")(environment)
  symbol[SetVideo](library, "retro_set_video_refresh")(video)
  symbol[SetAudio](library, "retro_set_audio_sample")(sample)
  symbol[SetBatch](library, "retro_set_audio_sample_batch")(batch)
  symbol[SetPoll](library, "retro_set_input_poll")(poll)
  symbol[SetInput](library, "retro_set_input_state")(input)
  init()
  defer: deinit()
  checkCallbacks()
  var game = RetroGameInfo(path: options.romPath.cstring, data: rom[0].unsafeAddr,
    size: rom.len.csize_t)
  if not loadGame(addr game):
    raise newException(IOError, "The shared core rejected the supplied ROM.")
  defer: unloadGame()
  checkCallbacks()
  if options.statePath.len > 0:
    let state = readFile(options.statePath)
    if state.len == 0 or not unserialize(state[0].unsafeAddr, state.len.csize_t):
      raise newException(IOError, "The shared core rejected the startup state.")
    checkCallbacks()
  for frame in 0 ..< options.warmup:
    callbacks.frame = frame
    run()
    checkCallbacks()
  callbacks.videoCalls = 0
  callbacks.audioFrames = 0
  callbacks.pollCalls = 0
  callbacks.videoBytes = 0
  callbacks.hashing = options.hash
  var wallTimes, cpuTimes = newSeq[int64](options.frames)
  discard threadCpuNs()
  for frame in 0 ..< options.frames:
    callbacks.frame = options.warmup + frame
    let
      videoBefore = callbacks.videoCalls
      pollBefore = callbacks.pollCalls
      wallStart = getMonoTime().ticks
      cpuStart = threadCpuNs()
    run()
    let
      cpuEnd = threadCpuNs()
      wallEnd = getMonoTime().ticks
    wallTimes[frame] = wallEnd - wallStart
    cpuTimes[frame] = cpuEnd - cpuStart
    checkCallbacks()
    if callbacks.videoCalls != videoBefore + 1 or callbacks.pollCalls <= pollBefore:
      raise newException(IOError, "Expected video and input callbacks for every frame.")
  result = %*{
    "schema": 1,
    "core_path": options.corePath,
    "core_library": $info.libraryName,
    "core_version": $info.libraryVersion,
    "host_nim_version": NimVersion,
    "host_danger": defined(danger),
    "frames": options.frames,
    "warmup_frames": options.warmup,
    "dual_screen": options.dualScreen,
    "opaque_xbgr_offered": options.xbgr,
    "opaque_xbgr_accepted": callbacks.opaqueAccepted,
    "walk": options.walk,
    "walk_period_frames": WalkPeriod,
    "state_imported": options.statePath.len > 0,
    "hashing_in_timed_callbacks": options.hash,
    "timing_unit": "ns",
    "timing_scope": "retro_run plus in-memory callbacks and clock reads; excludes startup and warmup",
    "wall_ns": wallTimes,
    "wall_summary_ns": statistics(wallTimes),
    "thread_cpu_supported": defined(linux),
    "thread_cpu_scope": "calling thread only; excludes any worker threads",
    "video_calls": callbacks.videoCalls,
    "video_bytes": callbacks.videoBytes,
    "audio_stereo_frames": callbacks.audioFrames,
    "input_polls": callbacks.pollCalls,
    "video_width": callbacks.width.int,
    "video_height": callbacks.height.int,
    "video_pitch": callbacks.pitch.int
  }
  when defined(linux):
    result["thread_cpu_ns"] = %cpuTimes
    result["thread_cpu_summary_ns"] = statistics(cpuTimes)
  else:
    result["thread_cpu_ns"] = newJNull()
    result["thread_cpu_summary_ns"] = newJNull()
    result["thread_cpu_unsupported_reason"] = %"CLOCK_THREAD_CPUTIME_ID is implemented for Linux only."
  if options.hash:
    result["hashes"] = %*{
      "algorithm": "CRC32/ISO-HDLC",
      "scope": "measured callbacks only, followed by final exposed WRAM/SRAM; warmup excluded",
      "video_crc32": (callbacks.videoCrc xor CrcInitial).int64,
      "pcm_crc32": (callbacks.audioCrc xor CrcInitial).int64,
      "wram": memoryHash(library, RetroMemorySystemRam),
      "sram": memoryHash(library, RetroMemorySaveRam)
    }

proc main() =
  ## Write only the JSON profiling report beneath the local ignored bin tree.
  let
    options = parseOptions()
    report = profile(options)
  createDir(options.outPath.parentDir)
  writeFile(options.outPath, report.pretty() & "\n")
  echo "Profiled ", options.frames, " frames; numeric report: ", options.outPath

when isMainModule:
  main()
