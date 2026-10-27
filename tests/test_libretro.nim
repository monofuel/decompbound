import
  std/[dynlib, os, osproc, strutils]

type
  GameInfo {.bycopy.} = object
    path: cstring
    data: pointer
    size: csize_t
    meta: cstring
  Environment = proc(command: cuint, data: pointer): bool {.cdecl.}
  Video = proc(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.}
  Poll = proc() {.cdecl.}
  Input = proc(port, device, index, id: cuint): int16 {.cdecl.}
  SetEnvironment = proc(callback: Environment) {.cdecl.}
  SetVideo = proc(callback: Video) {.cdecl.}
  SetPoll = proc(callback: Poll) {.cdecl.}
  SetInput = proc(callback: Input) {.cdecl.}
  VoidProc = proc() {.cdecl.}
  LoadGame = proc(game: ptr GameInfo): bool {.cdecl.}

const
  CorePath = "bin/libretro/decompbound_libretro.so"
  HostPath = "bin/libretro/test_host"
  HostSource = "tests/fixtures/libretro_host.c"
  RomSize = 3 * 1024 * 1024
  PixelFormatCommand = 10'u32
  Xrgb8888 = 1'u32

var
  videoCount: int
  pollCount: int

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Accept the core's requested 32-bit pixel format.
  result = command == PixelFormatCommand and data != nil and
    cast[ptr cuint](data)[] == Xrgb8888

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Validate a frame delivered to a Nim frontend.
  doAssert data != nil and width == 256 and height == 224 and pitch == 1024
  inc videoCount

proc poll() {.cdecl.} =
  ## Count the frontend input polls.
  inc pollCount

proc input(port, device, index, id: cuint): int16 {.cdecl.} =
  ## Leave all frontend buttons released.
  discard port
  discard device
  discard index
  discard id
  result = 0

proc symbol[T](library: LibHandle, name: string): T =
  ## Resolve one required ABI symbol or fail the test.
  let address = symAddr(library, name)
  doAssert address != nil, "Missing libretro symbol: " & name
  result = cast[T](address)

proc checkNimHost() =
  ## Exercise the shared core from another Nim runtime in this process.
  videoCount = 0
  pollCount = 0
  let library = loadLib(CorePath)
  doAssert library != nil, "Cannot load " & CorePath
  let
    setEnvironment = symbol[SetEnvironment](library, "retro_set_environment")
    setVideo = symbol[SetVideo](library, "retro_set_video_refresh")
    setPoll = symbol[SetPoll](library, "retro_set_input_poll")
    setInput = symbol[SetInput](library, "retro_set_input_state")
    init = symbol[VoidProc](library, "retro_init")
    deinit = symbol[VoidProc](library, "retro_deinit")
    loadGame = symbol[LoadGame](library, "retro_load_game")
    run = symbol[VoidProc](library, "retro_run")
    unloadGame = symbol[VoidProc](library, "retro_unload_game")
  setEnvironment(environment)
  setVideo(video)
  setPoll(poll)
  setInput(input)
  init()
  var rom = newSeq[byte](RomSize)
  # A 65816 infinite loop at $008000, with a synthetic HiROM header.
  rom[0x8000] = 0x4c
  rom[0x8001] = 0x00
  rom[0x8002] = 0x80
  for i, c in "SYNTHETIC NIM HOST   ":
    rom[0xffc0 + i] = byte(c)
  rom[0xffd5] = 0x21
  rom[0xfffc] = 0x00
  rom[0xfffd] = 0x80
  var game = GameInfo(data: addr rom[0], size: rom.len.csize_t)
  doAssert loadGame(addr game)
  run()
  doAssert videoCount == 1 and pollCount >= 1
  unloadGame()
  deinit()
  unloadLib(library)

proc main() =
  ## Build and run the independent C host and then a Nim host.
  doAssert execShellCmd("make libretro") == 0, "Failed to build the libretro core"
  let exports = execCmdEx("nm -D --defined-only " & quoteShell(CorePath))
  doAssert exports.exitCode == 0, exports.output
  let symbols = exports.output.strip().splitLines()
  doAssert symbols.len == 25, "Unexpected exported symbol count."
  for line in symbols:
    doAssert line.splitWhitespace()[^1].startsWith("retro_"), line
  let dependencies = execCmdEx("readelf -Wd " & quoteShell(CorePath))
  doAssert dependencies.exitCode == 0, dependencies.output
  for line in dependencies.output.splitLines():
    if "(NEEDED)" in line:
      let name = line.split('[')[1].split(']')[0]
      doAssert name.startsWith("libc.so") or name.startsWith("libm.so") or
        name.startsWith("librt.so") or name.startsWith("libdl.so") or
        name.startsWith("libpthread.so") or name.startsWith("libgcc_s.so") or
        name.startsWith("ld-linux"), "Unexpected native dependency: " & name
  createDir(parentDir(HostPath))
  let compile = "cc -std=c11 -Wall -Wextra -Werror " & quoteShell(HostSource) &
    " -ldl -o " & quoteShell(HostPath)
  doAssert execShellCmd(compile) == 0, "Failed to compile the C host"
  doAssert execShellCmd(quoteShell(HostPath) & " " & quoteShell(CorePath)) == 0,
    "Libretro C host failed"
  for cycle in 0 ..< 8:
    checkNimHost()
    let hostAllocation = repeat("frontend", 1024 + cycle)
    doAssert hostAllocation.len == "frontend".len * (1024 + cycle)

when isMainModule:
  main()
