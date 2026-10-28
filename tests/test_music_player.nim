import
  std/[unittest],
  decompbound/[common, music_player]

const
  SongTable = 0x04F70A
  PackTable = 0x04F947
  DriverPackage = 0x200000

proc syntheticRom(): seq[uint8] =
  ## Build our own tiny halted SPC program inside a synthetic ROM container.
  result = newSeq[uint8](EarthboundRomSize)
  for i in 0 ..< SongCount * 3: result[SongTable + i] = 0xFF
  result[SongTable] = 2
  result[SongTable + 3] = 2
  for pack in [1, 2]:
    result[PackTable + pack * 3] = 0xE0
    result[PackTable + pack * 3 + 1] = 0
    result[PackTable + pack * 3 + 2] = 0
  let blockBytes = [1'u8, 0, 0, 5, 0xFF, 0, 0]
  for i, value in blockBytes: result[DriverPackage + i] = value

suite "Music package decoding":
  test "a terminator is exactly two bytes, with no destination word":
    var ram: array[0x10000, uint8]
    ram[5] = 0xCC
    applyPackageBlocks(ram, [0'u8, 0], 0)
    check ram[5] == 0xCC
    applyPackageBlocks(ram, [2'u8, 0, 5, 0, 0x12, 0x34, 0, 0], 0)
    check ram[5] == 0x12 and ram[6] == 0x34

  test "uploads preserve ordered overlays and allow the last RAM byte":
    var ram: array[0x10000, uint8]
    applyPackageBlocks(ram, [2'u8, 0, 5, 0, 1, 2,
      1, 0, 6, 0, 3, 1, 0, 0xFF, 0xFF, 7, 0, 0], 0)
    check ram[5] == 1 and ram[6] == 3 and ram[0xFFFF] == 7

  test "truncated blocks, missing terminators, and overflowing destinations fail":
    var ram: array[0x10000, uint8]
    for bytes in [@[1'u8], @[1'u8, 0], @[1'u8, 0, 5],
      @[2'u8, 0, 5, 0, 1], @[1'u8, 0, 5, 0, 1],
      @[2'u8, 0, 0xFF, 0xFF, 1, 2, 0, 0]]:
      expect ValueError: applyPackageBlocks(ram, bytes, 0)
    expect ValueError: applyPackageBlocks(ram, [0'u8, 0], -1)
    expect ValueError: applyPackageBlocks(ram, [0'u8, 0], 3)

  test "song and pack references reject bad ids and truncated tables":
    var rom = syntheticRom()
    check songPackIndices(rom, 1) == @[2]
    check packFileOffset(rom, 1) == DriverPackage
    check songIsUnused(rom, 3)
    for id in [0, 192]:
      expect ValueError: discard songPackIndices(rom, id)
    for id in [-1, 169]:
      expect ValueError: discard packFileOffset(rom, id)
    rom[SongTable] = 169
    expect ValueError: discard songPackIndices(rom, 1)
    rom[PackTable + 3] = 0xFF
    expect ValueError: discard packFileOffset(rom, 1)
    expect ValueError: discard songPackIndices([0'u8], 1)
    expect ValueError: discard packFileOffset([0'u8], 1)

suite "Music player transport":
  test "catalog owns its ROM and accepts the optional copier header":
    var rom = syntheticRom()
    let library = newMusicLibrary(rom)
    check library.trackIds == @[1, 2]
    rom[SongTable] = 169
    let player = newMusicPlayer(library)
    defer: player.stop()
    player.startTrack(1)
    check player.state == Playing
    let headered = newSeq[uint8](512) & syntheticRom()
    check newMusicLibrary(headered).trackIds == @[1, 2]
    expect ValueError: discard newMusicLibrary([0'u8])
    expect ValueError: discard newMusicPlayer(nil)

  test "pause freezes playback, resume advances, and stop clears the transport":
    let player = newMusicPlayer(newMusicLibrary(syntheticRom()))
    var pcm = @[123'i16]
    player.togglePause()
    player.renderPcm(10, pcm)
    check pcm.len == 0 and player.state == Stopped
    player.startTrack(1)
    player.renderPcm(512, pcm)
    check pcm.len == 1024 and player.renderedFrames == 512
    player.togglePause()
    player.renderPcm(1000, pcm)
    check pcm.len == 0 and player.renderedFrames == 512 and player.state == Paused
    player.togglePause()
    player.renderPcm(3, pcm)
    check pcm.len == 6 and player.renderedFrames == 515
    player.stop()
    check player.songId == 0 and player.renderedFrames == 0 and player.state == Stopped
    player.renderPcm(10, pcm)
    check pcm.len == 0
    player.stop()

  test "bad track changes fail without replacing a playing song":
    let player = newMusicPlayer(newMusicLibrary(syntheticRom()))
    defer: player.stop()
    player.startTrack(1)
    for id in [0, 3, 192]:
      expect ValueError: player.startTrack(id)
      check player.songId == 1 and player.state == Playing
    var pcm: seq[int16]
    expect ValueError: player.renderPcm(-1, pcm)
