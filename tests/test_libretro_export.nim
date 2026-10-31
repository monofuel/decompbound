import
  std/dynlib,
  pixie,
  ../src/decompbound/[cpu, libretro_api, png_state, rom_pipeline, save_state, snesbus],
  ./fixtures/synthetic_ui_rom

type
  VoidProc = proc() {.cdecl.}
  LoadGame = proc(info: ptr RetroGameInfo): bool {.cdecl.}
  SerializeSize = proc(): csize_t {.cdecl.}
  Serialize = proc(data: pointer, size: csize_t): bool {.cdecl.}
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
  GoldFrames = 12

proc symbol[T](library: LibHandle, name: string): T =
  ## Resolve an ABI entrypoint from the actual shared library.
  let address = symAddr(library, name)
  doAssert address != nil, "Missing libretro symbol: " & name
  cast[T](address)

proc environment(command: cuint, data: pointer): bool {.cdecl.} =
  ## Select software video without dual-screen or achievement setup.
  if command == RetroEnvSetPixelFormat:
    return cast[ptr cuint](data)[] == RetroPixelFormatXrgb8888
  if command == RetroEnvSetVariables:
    return true

proc video(data: pointer, width, height: cuint, pitch: csize_t) {.cdecl.} =
  ## Accept a software frame from the core without presenting it.
  doAssert data != nil and width == 256 and height == 224 and pitch == 1024

proc trailerLength(buffer: seq[uint8]): int =
  ## Read the little-endian DBST length stored at the end of an export envelope.
  let n = buffer.len
  buffer[n - 4].int or (buffer[n - 3].int shl 8) or
    (buffer[n - 2].int shl 16) or (buffer[n - 1].int shl 24)

proc envelopePayload(buffer: seq[uint8]): seq[uint8] =
  ## Slice the DBST payload out of a fixed-size export envelope.
  let n = trailerLength(buffer)
  doAssert n >= 8 and n <= buffer.len - 4
  buffer[0 ..< n]

proc makeSyntheticRom(): seq[uint8] =
  ## Authored BRA -2 program at the reset entry; no game code or assets.
  result = newSeq[uint8](RomSize)
  result.addSyntheticUi()
  result[ResetEntry] = 0x80
  result[ResetEntry + 1] = 0xFE
  result[0xFFD5] = 0x21
  result[ResetVector] = uint8(ResetEntry and 255)
  result[ResetVector + 1] = uint8(ResetEntry shr 8)

proc main() =
  ## Verify libretro export size, padding, DBST import compatibility, and round-trip equality.
  let library = loadLib(CorePath)
  doAssert library != nil, "Build the libretro core first"
  defer: unloadLib(library)
  let
    init = symbol[VoidProc](library, "retro_init")
    deinit = symbol[VoidProc](library, "retro_deinit")
    load = symbol[LoadGame](library, "retro_load_game")
    unload = symbol[VoidProc](library, "retro_unload_game")
    serializeSize = symbol[SerializeSize](library, "retro_serialize_size")
    save = symbol[Serialize](library, "retro_serialize")
    restore = symbol[Unserialize](library, "retro_unserialize")
    memory = symbol[MemoryData](library, "retro_get_memory_data")
    run = symbol[VoidProc](library, "retro_run")
  symbol[SetEnvironment](library, "retro_set_environment")(environment)
  symbol[SetVideo](library, "retro_set_video_refresh")(video)
  init()
  defer: deinit()
  doAssert serializeSize() == 0
  var tiny: uint8
  doAssert not save(addr tiny, 1)
  doAssert not restore(addr tiny, 1)
  doAssert not save(nil, MaxStateBytes.csize_t)
  doAssert not restore(nil, MaxStateBytes.csize_t)

  var rom = makeSyntheticRom()
  var game = RetroGameInfo(data: addr rom[0], size: rom.len.csize_t)
  doAssert load(addr game)
  let envelope = serializeSize()
  doAssert envelope == MaxStateBytes.csize_t
  doAssert not save(addr tiny, 1)
  doAssert not save(nil, envelope)
  doAssert not restore(addr tiny, 0)
  doAssert not restore(nil, envelope)

  let
    source = newSnesBus(rom)
  var sourceCpu = source.resetCpu()
  doAssert sourceCpu.pc == ResetEntry
  source.bus.mem[WramBase + Witness] = 0xAA
  source.sram[0] = 0x55
  let raw = serializeState(source, sourceCpu)
  let
    wram = cast[ptr UncheckedArray[uint8]](memory(RetroMemorySystemRam))
    sram = cast[ptr UncheckedArray[uint8]](memory(RetroMemorySaveRam))
  wram[Witness] = 1
  sram[0] = 9
  var extra = raw & @[0'u8]
  doAssert not restore(unsafeAddr extra[0], extra.len.csize_t)
  doAssert wram[Witness] == 1 and sram[0] == 9
  doAssert restore(unsafeAddr raw[0], raw.len.csize_t)
  doAssert wram[Witness] == 0xAA and sram[0] == 0x55

  var exported = newSeq[uint8](envelope.int)
  doAssert save(addr exported[0], envelope)
  doAssert exported.len == envelope.int
  doAssert serializeSize() == envelope
  doAssert envelopePayload(exported) == raw
  var invalidPadding = exported
  invalidPadding[raw.len + 1] = 1
  doAssert not restore(addr invalidPadding[0], envelope)
  wram[Witness] = 1
  sram[0] = 9
  doAssert restore(addr exported[0], envelope)
  doAssert wram[Witness] == 0xAA and sram[0] == 0x55
  var exportedAgain = newSeq[uint8](envelope.int)
  doAssert save(addr exportedAgain[0], envelope)
  doAssert exportedAgain == exported

  let png = embedState(cast[seq[uint8]](newImage(1, 1).encodeImage(PngFormat)), raw,
    romHashOf(rom))
  wram[Witness] = 1
  doAssert restore(unsafeAddr png[0], png.len.csize_t)
  doAssert wram[Witness] == 0xAA

  let paddedPng = embedState(cast[seq[uint8]](newImage(1, 1).encodeImage(PngFormat)),
    exportedAgain, romHashOf(rom))
  wram[Witness] = 1
  doAssert restore(unsafeAddr paddedPng[0], paddedPng.len.csize_t)
  doAssert wram[Witness] == 0xAA

  run()
  doAssert serializeSize() == envelope
  doAssert save(addr exported[0], envelope)
  doAssert envelopePayload(exported)[0 ..< 4] == @[byte('D'), byte('B'), byte('S'), byte('T')]
  wram[Witness] = 0x11
  doAssert restore(addr exportedAgain[0], envelope)
  doAssert wram[Witness] == 0xAA and sram[0] == 0x55
  unload()
  doAssert serializeSize() == 0
  doAssert not save(addr exported[0], envelope)

  if goldBaseromAvailable():
    var gold = readGoldBaserom()
    var goldGame = RetroGameInfo(data: addr gold[0], size: gold.len.csize_t)
    doAssert load(addr goldGame)
    defer: unload()
    doAssert serializeSize() == envelope
    for _ in 0 ..< GoldFrames:
      run()
    doAssert serializeSize() == envelope
    var first = newSeq[uint8](envelope.int)
    doAssert save(addr first[0], envelope)
    let firstPayload = envelopePayload(first)
    doAssert firstPayload.len >= 8
    doAssert firstPayload[0 ..< 4] == @[byte('D'), byte('B'), byte('S'), byte('T')]
    let
      goldWram = cast[ptr UncheckedArray[uint8]](memory(RetroMemorySystemRam))
      goldSram = cast[ptr UncheckedArray[uint8]](memory(RetroMemorySaveRam))
      witnessByte = goldWram[Witness]
      sramByte = goldSram[0]
    goldWram[Witness] = witnessByte xor 0xFF
    goldSram[0] = sramByte xor 0xFF
    doAssert restore(addr first[0], envelope)
    doAssert goldWram[Witness] == witnessByte and goldSram[0] == sramByte
    var second = newSeq[uint8](envelope.int)
    doAssert save(addr second[0], envelope)
    doAssert second == first
    doAssert serializeSize() == envelope

main()
