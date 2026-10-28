## Standalone numeric-id music player for EarthBound APU packages.
##
## Loads the user's ROM, resolves song-table pack indices, uploads packages
## into a fresh APU the way `src/tools/sound_explore.nim` does, and renders
## interleaved stereo PCM. Direct package load skips the S-CPU/IPL handshake;
## resident pack 1 is prepended when a song omits it so a cold APU still has
## the driver at `$0500` (docs/audio.md).

import
  std/strformat,
  ./[apu, common]

type
  ## Transport state of a `MusicPlayer`.
  PlaybackState* = enum
    Stopped
    Playing
    Paused

  ## ROM-backed catalog of numeric song ids.
  MusicLibrary* = ref object
    trackIds*: seq[int]
    rom: seq[uint8]

  ## Standalone APU playback of one library track.
  MusicPlayer* = ref object
    songId*: int
    state*: PlaybackState
    renderedFrames*: int64
    library*: MusicLibrary
    apu: Apu

const
  ## SPC/DSP output rate used by `apu.runSample` (1.024 MHz / 32 cycles).
  MusicSampleRate* = 32000
  ## Song table at file `$04F70A`; three pack-index bytes per 1-based id.
  ## Evidence: docs/audio.md, `asm/loadSong.asm`, `battle_music.nim`.
  SongTableFile = 0x04F70A
  ## Pack table at file `$04F947`; three bytes per pack, bank/addr-low/addr-high.
  PackTableFile = 0x04F947
  ## First byte after the last pack-table entry (`$04FB41` inclusive).
  ## The `$C4FB42` RTS helper sits here (`asm/loadSong.asm`).
  PackTableEnd = 0x04FB42
  SongRowSize = 3
  PackEntrySize = 3
  ## 191 rows: (`$04F947` - `$04F70A`) / 3.
  SongCount* = (PackTableFile - SongTableFile) div SongRowSize
  ## 169 entries, indices 0..168 (docs/audio.md).
  PackCount = (PackTableEnd - PackTableFile) div PackEntrySize
  ## `$FF` in a song-table slot means that pack is absent (`asm/loadSong.asm`).
  UnusedPackSlot = 0xFF
  ## Package 1 carries the `$0500` driver/bootstrap (docs/audio.md `$260000`).
  ResidentPackIndex = 1
  ## HiROM file mapping used by `sound_explore.nim`: `(bank & $3F) << 16 | addr`.
  HiRomBankMask = 0x3F
  CopierHeaderSize = 512
  ApuRamSize = 0x10000
  LengthWordSize = 2
  DestWordSize = 2
  ## `$C0AB06` zero-length terminator substitutes entry `$0500`.
  DriverEntry = 0x0500'u16
  ## IPL `MOV X,#$EF` / `MOV SP,X` (`spc700.IplRom`); same as `bootWithIpl`.
  IplStackPointer = 0xEF'u8
  ## `sound_explore.nim` re-pokes the song id every `SampleRate div 2` samples.
  SongCommandPeriodFrames = MusicSampleRate div 2
  ## Samples to let the uploaded driver initialize before port pokes.
  ## Copied from `sound_explore.nim` (`SampleRate div 5`).
  ## TODO: replace with a traced driver-ready wait once that handshake is known.
  DriverInitFrames = MusicSampleRate div 5
  ## Samples between each CLI start-protocol port poke (`SampleRate div 200`).
  ## TODO: replace with the S-CPU wait actually used by the port helpers.
  PortGapFrames = MusicSampleRate div 200
  ## Opaque byte poked to `$2143` by `writeApuPort3Cmd57` at `$C0AC01`.
  ## TODO: identify what the resident driver does with `$57` on port 3.
  ApuPort3Command57 = 0x57'u8
  ## CLI writes `1` to `$2141`. The game's `writeApuPort1Toggled` ORs A with
  ## WRAM `$1ACB`; a fresh standalone APU has no S-CPU latch, so the CLI
  ## writes the low command bit alone.
  ## TODO: confirm whether omitting the `$1ACB` phase bit changes the handshake.
  ApuPort1StartCommand = 0x01'u8
  ## Zero written to `$2140` between the port-1 poke and the song id.
  ## CLI mirrors the `$C0ABC6` ack used after the stop handshake.
  ApuPort0Ack = 0x00'u8

when SongCount != 191:
  {.error: "song table extent is not 191 rows".}
when PackCount != 169:
  {.error: "pack table extent is not 169 entries".}

proc readLeU16(data: openArray[uint8], pos: int): int =
  ## Read a little-endian 16-bit word at `pos` as a non-negative int.
  data[pos].int or (data[pos + 1].int shl 8)

proc requireSongId(songId: int) =
  ## Reject song ids outside the 1-based table `1..SongCount`.
  if songId < 1 or songId > SongCount:
    raise newException(ValueError, &"song id {songId} is outside 1..{SongCount}")

proc songTableBase(rom: openArray[uint8], songId: int): int =
  ## File offset of the three-byte song-table row for `songId`.
  requireSongId(songId)
  result = SongTableFile + (songId - 1) * SongRowSize
  if result < 0 or result + SongRowSize > rom.len:
    raise newException(ValueError, &"song table row for id {songId} overruns source")

proc songIsUnused*(rom: openArray[uint8], songId: int): bool =
  ## True when all three pack slots for `songId` are `$FF`.
  let base = songTableBase(rom, songId)
  result =
    rom[base] == UnusedPackSlot.uint8 and
    rom[base + 1] == UnusedPackSlot.uint8 and
    rom[base + 2] == UnusedPackSlot.uint8

proc songPackIndices*(rom: openArray[uint8], songId: int): seq[int] =
  ## Pack indices for `songId`, skipping `$FF` slots, in table order.
  let base = songTableBase(rom, songId)
  result = @[]
  for i in 0 ..< SongRowSize:
    let packIdx = rom[base + i].int
    if packIdx == UnusedPackSlot:
      continue
    if packIdx < 0 or packIdx >= PackCount:
      raise newException(
        ValueError,
        &"song {songId} pack slot {i} index {packIdx} is outside 0..{PackCount - 1}"
      )
    result.add(packIdx)

proc packFileOffset*(rom: openArray[uint8], packIdx: int): int =
  ## HiROM file offset of pack `packIdx` from the pack-table far pointer.
  if packIdx < 0 or packIdx >= PackCount:
    raise newException(ValueError, &"pack index {packIdx} is outside 0..{PackCount - 1}")
  let base = PackTableFile + packIdx * PackEntrySize
  if base < 0 or base + PackEntrySize > rom.len:
    raise newException(ValueError, &"pack table entry {packIdx} overruns source")
  let
    bank = rom[base].int
    lo = rom[base + 1].int
    hi = rom[base + 2].int
  result = ((bank and HiRomBankMask) shl 16) or ((hi shl 8) or lo)
  if result < 0 or result >= rom.len:
    raise newException(
      ValueError,
      &"pack {packIdx} file offset 0x{result:06X} is outside source"
    )

proc applyPackageBlocks*(
    ram: var array[0x10000, uint8],
    data: openArray[uint8],
    fileOff: int
) =
  ## Copy one `$C0AB06` package into APU RAM.
  ##
  ## Nonempty blocks are `[u16 length][u16 dest][payload]`. A two-byte zero
  ## length is the terminator and does not consume a destination word.
  if fileOff < 0 or fileOff > data.len:
    raise newException(ValueError, &"package start {fileOff} is outside source")
  var
    pos = fileOff
    terminated = false
  while not terminated:
    if pos + LengthWordSize > data.len:
      raise newException(ValueError, "package truncated before length word")
    let length = readLeU16(data, pos)
    pos += LengthWordSize
    if length == 0:
      terminated = true
    else:
      if pos + DestWordSize > data.len:
        raise newException(ValueError, "package truncated before destination word")
      let dest = readLeU16(data, pos)
      pos += DestWordSize
      if length > data.len - pos:
        raise newException(ValueError, "package payload overruns source")
      if dest + length > ApuRamSize:
        raise newException(
          ValueError,
          &"package destination 0x{dest:04X}+{length} overruns APU RAM"
        )
      for i in 0 ..< length:
        ram[dest + i] = data[pos + i]
      pos += length

proc collectTrackIds(rom: openArray[uint8]): seq[int] =
  ## Numeric ids in `1..SongCount` whose song-table row is not unused.
  result = @[]
  for songId in 1 .. SongCount:
    if not songIsUnused(rom, songId):
      result.add(songId)

proc copyRomBody(rom: openArray[uint8]): seq[uint8] =
  ## Strip an optional 512-byte copier header and require a 3 MiB body.
  var start = 0
  if rom.len mod 1024 == CopierHeaderSize:
    start = CopierHeaderSize
  let bodyLen = rom.len - start
  if bodyLen != EarthboundRomSize:
    raise newException(
      ValueError,
      &"ROM size {bodyLen} != {EarthboundRomSize} (optional {CopierHeaderSize}-byte header stripped)"
    )
  result = newSeq[uint8](EarthboundRomSize)
  for i in 0 ..< EarthboundRomSize:
    result[i] = rom[start + i]

proc runSilentSamples(machine: Apu, frames: int) =
  ## Advance the APU `frames` samples without capturing PCM.
  for _ in 0 ..< frames:
    discard machine.runSample()

proc loadStandaloneApu(rom: openArray[uint8], songId: int): Apu =
  ## Fresh APU with this song's packages and the CLI start protocol applied.
  var packs = songPackIndices(rom, songId)
  if ResidentPackIndex notin packs:
    packs = @[ResidentPackIndex] & packs
  var apuRam: array[0x10000, uint8]
  for packIdx in packs:
    applyPackageBlocks(apuRam, rom, packFileOffset(rom, packIdx))
  result = newApu()
  for i in 0 ..< ApuRamSize:
    result.spc.ram[i] = apuRam[i]
  result.spc.pc = DriverEntry
  result.spc.sp = IplStackPointer
  result.spc.a = 0
  result.spc.x = 0
  result.spc.y = 0
  result.spc.psw = 0
  runSilentSamples(result, DriverInitFrames)
  result.portsIn[3] = ApuPort3Command57
  runSilentSamples(result, PortGapFrames)
  result.portsIn[1] = ApuPort1StartCommand
  runSilentSamples(result, PortGapFrames)
  result.portsIn[0] = ApuPort0Ack
  runSilentSamples(result, PortGapFrames)
  result.portsIn[0] = uint8(songId and 0xFF)

proc newMusicLibrary*(rom: openArray[uint8]): MusicLibrary =
  ## Build a library from ROM bytes, stripping an optional 512-byte header.
  let body = copyRomBody(rom)
  result = MusicLibrary(trackIds: collectTrackIds(body), rom: body)

proc loadMusicLibrary*(path: string): MusicLibrary =
  ## Read `path` and build a `MusicLibrary` from those bytes.
  let data = readFile(path)
  var bytes = newSeq[uint8](data.len)
  for i, ch in data:
    bytes[i] = ch.uint8
  result = newMusicLibrary(bytes)

proc newMusicPlayer*(library: MusicLibrary): MusicPlayer =
  ## Stopped player bound to `library`.
  if library.isNil:
    raise newException(ValueError, "music library is nil")
  result = MusicPlayer(library: library, state: Stopped, songId: 0, renderedFrames: 0)

proc releaseApu(player: MusicPlayer) =
  ## Break the APU's self-capturing port hooks before releasing a song machine.
  if player.apu != nil:
    player.apu.spc.readHook = nil
    player.apu.spc.writeHook = nil
    player.apu = nil

proc startTrack*(player: MusicPlayer, songId: int) =
  ## Load `songId` into a fresh APU and begin playback.
  if player.isNil:
    raise newException(ValueError, "music player is nil")
  if player.library.isNil:
    raise newException(ValueError, "music library is nil")
  requireSongId(songId)
  if songIsUnused(player.library.rom, songId):
    raise newException(ValueError, &"song id {songId} is unused")
  let machine = loadStandaloneApu(player.library.rom, songId)
  player.releaseApu()
  player.apu = machine
  player.songId = songId
  player.state = Playing
  player.renderedFrames = 0

proc togglePause*(player: MusicPlayer) =
  ## Switch between `Playing` and `Paused`; `Stopped` is left unchanged.
  if player.isNil:
    raise newException(ValueError, "music player is nil")
  if player.state == Playing:
    player.state = Paused
  elif player.state == Paused:
    player.state = Playing

proc stop*(player: MusicPlayer) =
  ## Drop the APU image and return to `Stopped`.
  if player.isNil:
    raise newException(ValueError, "music player is nil")
  player.releaseApu()
  player.state = Stopped
  player.songId = 0
  player.renderedFrames = 0

proc renderPcm*(player: MusicPlayer, frameCount: int, output: var seq[int16]) =
  ## Fill `output` with `frameCount` interleaved stereo frames, or empty it.
  if player.isNil:
    raise newException(ValueError, "music player is nil")
  if frameCount < 0:
    raise newException(ValueError, &"frame count {frameCount} is negative")
  if frameCount > high(int) div 2:
    raise newException(ValueError, "frame count is too large for stereo PCM")
  if player.state != Playing or player.apu.isNil:
    output.setLen(0)
  else:
    output.setLen(frameCount * 2)
    for i in 0 ..< frameCount:
      if player.renderedFrames > 0 and
          player.renderedFrames mod SongCommandPeriodFrames == 0:
        player.apu.portsIn[0] = uint8(player.songId and 0xFF)
      let pair = player.apu.runSample()
      output[i * 2] = pair.left
      output[i * 2 + 1] = pair.right
      inc player.renderedFrames
