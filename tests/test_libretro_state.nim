import
  std/[dynlib, strutils],
  pixie,
  ../src/decompbound/[cpu, libretro_api, png_state, save_state, snesbus],
  ./fixtures/synthetic_ui_rom

type
  VoidProc = proc() {.cdecl.}
  LoadGame = proc(info: ptr RetroGameInfo): bool {.cdecl.}
  Unserialize = proc(data: pointer, size: csize_t): bool {.cdecl.}
  MemoryData = proc(id: cuint): pointer {.cdecl.}
  SetEnvironment = proc(callback: RetroEnvironment) {.cdecl.}
  SetVideo = proc(callback: RetroVideoRefresh) {.cdecl.}

const
  CorePath = "bin/libretro/decompbound_libretro.so"
  RomSize = 3 * 1024 * 1024
  WramBase = 0x7E0000
  Witness = 0x1234
  ResetEntry = 0x8141
  ResetVector = 0xFFFC
  VersionTwoTail = 3 * (4 * sizeof(uint8) + sizeof(int32)) + sizeof(uint8)

var videoCalls: int

proc symbol[T](library: LibHandle, name: string): T =
  ## Resolve an ABI entrypoint from the actual shared library.
  let address = symAddr(library, name)
  doAssert address != nil
  cast[T](address)

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Select software video and the dual-screen preset for this independent host.
  if command == RetroEnvSetPixelFormat:
    return cast[ptr cuint](data)[] == RetroPixelFormatXrgb8888
  if command == RetroEnvSetVariables: return true
  if command == RetroEnvGetVariable:
    let variable = cast[ptr RetroVariable](data)
    if $variable.key == "decompbound_dual_screen":
      variable.value = "enabled"
      return true

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Check that restoring a state preserves the negotiated dual-screen output.
  doAssert data != nil and width == 256 and height == 448 and pitch == 1024
  inc videoCalls

proc main() =
  ## Verify raw/PNG import and rejection atomicity with wholly synthetic game state.
  var rom = newSeq[uint8](RomSize)
  rom.addSyntheticUi()
  # Authored BRA -2 program at the reset entry; no game code or assets.
  rom[ResetEntry] = 0x80
  rom[ResetEntry + 1] = 0xFE
  rom[0xFFD5] = 0x21 # Synthetic HiROM mapping, matching the supplied program layout.
  rom[ResetVector] = uint8(ResetEntry and 255)
  rom[ResetVector + 1] = uint8(ResetEntry shr 8)
  let machine = newSnesBus(rom)
  var state = machine.resetCpu()
  doAssert state.pc == ResetEntry
  machine.bus.mem[WramBase + Witness] = 0xAA
  machine.sram[0] = 0x55
  let
    raw = serializeState(machine, state)
    png = embedState(cast[seq[uint8]](newImage(1, 1).encodeImage(PngFormat)), raw, romHashOf(rom))
    wrongRom = embedState(cast[seq[uint8]](newImage(1, 1).encodeImage(PngFormat)), raw, romHashOf(rom) xor 1)
    plain = cast[seq[uint8]](newImage(1, 1).encodeImage(PngFormat))
    library = loadLib(CorePath)
  doAssert library != nil, "Build the libretro core first"
  defer: unloadLib(library)
  let
    init = symbol[VoidProc](library, "retro_init")
    deinit = symbol[VoidProc](library, "retro_deinit")
    load = symbol[LoadGame](library, "retro_load_game")
    unload = symbol[VoidProc](library, "retro_unload_game")
    restore = symbol[Unserialize](library, "retro_unserialize")
    memory = symbol[MemoryData](library, "retro_get_memory_data")
  symbol[SetEnvironment](library, "retro_set_environment")(environment)
  symbol[SetVideo](library, "retro_set_video_refresh")(video)
  init()
  defer: deinit()
  var game = RetroGameInfo(data: addr rom[0], size: rom.len.csize_t)
  doAssert load(addr game)
  defer: unload()
  let
    wram = cast[ptr UncheckedArray[uint8]](memory(RetroMemorySystemRam))
    sram = cast[ptr UncheckedArray[uint8]](memory(RetroMemorySaveRam))
  wram[Witness] = 1
  sram[0] = 9
  var
    badMagic = raw
    badVersion = raw
    badCrc = png
  badMagic[0] = 0
  badVersion[4] = 99
  let chunk = cast[string](badCrc).find("ebSt")
  doAssert chunk >= 0
  badCrc[chunk + 4 + 14] = badCrc[chunk + 4 + 14] xor 1
  for bad in [raw[0 .. 100], raw[0 ..< raw.len - 1], raw & @[0'u8],
      badMagic, badVersion, badCrc, wrongRom, plain]:
    doAssert not restore(unsafeAddr bad[0], bad.len.csize_t)
    doAssert wram[Witness] == 1 and sram[0] == 9
  doAssert restore(unsafeAddr raw[0], raw.len.csize_t)
  doAssert wram[Witness] == 0xAA and sram[0] == 0x55
  doAssert memory(RetroMemorySystemRam) == cast[pointer](wram)
  doAssert memory(RetroMemorySaveRam) == cast[pointer](sram)
  wram[Witness] = 1
  doAssert restore(unsafeAddr png[0], png.len.csize_t)
  doAssert wram[Witness] == 0xAA
  var legacy = raw[0 ..< raw.len - VersionTwoTail]
  legacy[4] = StateVersionMin.uint8
  doAssert restore(unsafeAddr legacy[0], legacy.len.csize_t)
  doAssert wram[Witness] == 0xAA and sram[0] == 0x55
  symbol[VoidProc](library, "retro_run")()
  doAssert videoCalls == 1

main()
