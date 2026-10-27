## Minimal C ABI declarations for the libretro v1 frontend interface.

type
  RetroEnvironment* = proc(command: cuint, data: pointer): bool {.cdecl.}
  RetroVideoRefresh* = proc(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.}
  RetroAudioSample* = proc(left, right: int16) {.cdecl.}
  RetroAudioSampleBatch* = proc(data: ptr int16, frames: csize_t): csize_t {.cdecl.}
  RetroInputPoll* = proc() {.cdecl.}
  RetroInputState* = proc(port, device, index, id: cuint): int16 {.cdecl.}
  RetroLog* = proc(level: cuint, format: cstring) {.cdecl, varargs.}
  RetroLogCallback* {.bycopy.} = object
    log*: RetroLog
  RetroGameInfo* {.bycopy.} = object
    path*: cstring
    data*: pointer
    size*: csize_t
    meta*: cstring
  RetroSystemInfo* {.bycopy.} = object
    libraryName*, libraryVersion*, validExtensions*: cstring
    needFullpath*, blockExtract*: bool
  RetroGameGeometry* {.bycopy.} = object
    baseWidth*, baseHeight*, maxWidth*, maxHeight*: cuint
    aspectRatio*: cfloat
  RetroSystemTiming* {.bycopy.} = object
    fps*, sampleRate*: cdouble
  RetroSystemAvInfo* {.bycopy.} = object
    geometry*: RetroGameGeometry
    timing*: RetroSystemTiming

const
  RetroApiVersion* = 1.cuint
  RetroEnvShutdown* = 7.cuint
  RetroEnvSetPixelFormat* = 10.cuint
  RetroEnvGetLogInterface* = 27.cuint
  RetroPixelFormatXrgb8888* = 1.cuint
  RetroDeviceNone* = 0.cuint
  RetroDeviceJoypad* = 1.cuint
  RetroMemorySaveRam* = 0.cuint
  RetroMemorySystemRam* = 2.cuint
  RetroRegionNtsc* = 0.cuint
  RetroLogError* = 3.cuint
