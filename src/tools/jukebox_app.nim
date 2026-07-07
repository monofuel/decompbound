## Interactive silky GUI jukebox for EarthBound APU music.
## Click a song in the scrollable list to play it live via slappy streaming (no WAV).
## ROM path from argv[1] or default; builds atlas into bin/ at startup.
## Does not touch emulator cores or sound_explore.nim.

import
  std/[os, strformat, strutils, monotimes, times],
  opengl,
  windy,
  bumpy,
  vmath,
  chroma,
  silky,
  slappy,
  ../decompbound/apu

# --- Copied verbatim from sound_explore.nim (file-private there; do not import) ---
const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  SampleRate = 32000
  SongTableFile = 0x04F70A
  PackTableFile = 0x04F947
  # Stub deposited at $0500 by IPL side of the upload protocol (when streamer forces
  # exec target $0500 on len=0). Captured from live APU+IPL during real package upload.
  # TODO: magic bytes from protocol side effect; reverse the small IPL bootstrap if needed.
  Ipl0500Stub: array[32, uint8] = [
    0x20'u8, 0xCD, 0xCF, 0xBD, 0xE8, 0x00, 0x5D, 0xAF,
    0xC8, 0xE0, 0xD0, 0xFB, 0x3F, 0xA5, 0x16, 0xE8,
    0x55, 0xC4, 0x18, 0xC4, 0x19, 0xE8, 0x00, 0xBC,
    0x3F, 0x2C, 0x0B, 0xA2, 0x48, 0xE8, 0x70, 0x8D
  ]

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM, strip optional 512-byte copier header.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc getSongPackIndices(rom: seq[uint8], songId: int): seq[int] =
  ## Lookup up to 3 pack indices for songId from the verified song table.
  ## 0xFF entries are skipped (unused).
  if songId < 1:
    quit("song id must be >= 1")
  let base = SongTableFile + (songId - 1) * 3
  if base + 2 >= rom.len:
    quit(&"song table overrun for id {songId}")
  result = @[]
  for i in 0..2:
    let p = rom[base + i].int
    if p != 0xFF:
      result.add(p)

proc packFileOffset(rom: seq[uint8], packIdx: int): int =
  ## Pack table entry -> far ptr -> file offset (HiROM mapping).
  let base = PackTableFile + packIdx * 3
  if base + 2 >= rom.len:
    quit(&"pack table overrun for idx {packIdx}")
  let bank = rom[base + 0]
  let lo = rom[base + 1]
  let hi = rom[base + 2]
  result = ((bank and 0x3F).int shl 16) or ((hi.int shl 8) or lo.int)

proc loadPackageToRam(ram: var array[0x10000, uint8], rom: seq[uint8], fileOff: int) =
  ## Replicate $C0AB06 package exactly: walk blocks, copy payloads to tgt RAM.
  var pos = fileOff
  while pos + 3 < rom.len:
    let len = (rom[pos + 0].int) or (rom[pos + 1].int shl 8)
    let tgt = (rom[pos + 2].int) or (rom[pos + 3].int shl 8)
    pos += 4
    if len == 0: break
    if pos + len > rom.len: break
    for i in 0..<len:
      let a = tgt + i
      if a >= 0 and a < 0x10000: ram[a] = rom[pos + i]
    pos += len

# --- App state (module scope so onFrame + templates see sk/window like silky examples) ---
var
  activeApu: Apu = nil
  currentSong = 0
  sampleCounter = 0
  rom: seq[uint8]
  songIds: seq[int] = @[]
  songLabels: seq[string] = @[]
  romPath = DefaultRom

# Parse first CLI arg (ROM path) at init time so make can pass $(ROM); default otherwise.
if paramCount() >= 1:
  let arg = paramStr(1)
  if arg.len > 0:
    romPath = arg

rom = readRomFile(romPath)

# Build song list from table extents. Song table is 3 bytes per entry.
# Skip slots where all three pack bytes are 0xFF (unused).
let songCount = (PackTableFile - SongTableFile) div 3
for id in 1 .. songCount:
  let base = SongTableFile + (id - 1) * 3
  if base + 2 >= rom.len: continue
  let p0 = rom[base + 0]
  let p1 = rom[base + 1]
  let p2 = rom[base + 2]
  if p0 == 0xFF'u8 and p1 == 0xFF'u8 and p2 == 0xFF'u8: continue
  songIds.add(id)
  songLabels.add(&"Song {id:03d}")

proc startSong(song: int) =
  ## Build a fresh APU image for the song (packs + IPL stub), boot driver,
  ## kick via ports, store as activeApu. Mirrors sound_explore main setup.
  if song < 1:
    return
  let r = if rom.len > 0: rom else: readRomFile(romPath)
  var packs = getSongPackIndices(r, song)
  if 1 notin packs:
    packs = @[1] & packs
  var apuRam: array[0x10000, uint8]
  for p in packs:
    let foff = packFileOffset(r, p)
    loadPackageToRam(apuRam, r, foff)
  if apuRam[0x0500] == 0:
    for i in 0..<Ipl0500Stub.len:
      apuRam[0x0500 + i] = Ipl0500Stub[i]
  let apu = newApu()
  for i in 0..<0x10000:
    apu.spc.ram[i] = apuRam[i]
  apu.spc.pc = 0x0500'u16
  apu.spc.sp = 0xEF'u8
  apu.spc.a = 0
  apu.spc.x = 0
  apu.spc.y = 0
  apu.spc.psw = 0
  for _ in 0 ..< (SampleRate div 5):
    discard apu.runSample()
  apu.portsIn[3] = 0x57'u8
  for _ in 0 ..< (SampleRate div 200):
    discard apu.runSample()
  apu.portsIn[1] = 1'u8
  for _ in 0 ..< (SampleRate div 200):
    discard apu.runSample()
  apu.portsIn[0] = 0'u8
  for _ in 0 ..< (SampleRate div 200):
    discard apu.runSample()
  apu.portsIn[0] = (song and 0xFF).uint8
  activeApu = apu
  currentSong = song
  sampleCounter = 0

createDir("bin")

# Build atlas from vendored silky theme (9-patches + font). bin/ is gitignored.
# Current silky embeds JSON in the PNG (single-arg write / newSilky).
let builder = newAtlasBuilder(1024, 4)
builder.addDir("data/silky/", "data/silky/")
builder.addFont("data/silky/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("data/silky/IBMPlexSans-Regular.ttf", "Default", 18.0)
builder.write("bin/jukebox_atlas.png")

let window = newWindow("EarthBound Jukebox", ivec2(520, 640), vsync = false)
makeContextCurrent(window)
loadExtensions()

let sk = newSilky(window, "bin/jukebox_atlas.png")

# Real-time slappy streaming source (32kHz stereo 16-bit), lives for session.
slappyInit()
let ss = newStreamingSource(frequency = 32000, channels = 2, bits = 16)

# Wall-clock pacing for audio frames (prevent backlog/latency runaway).
const TargetFrameNs = 1_000_000_000 div 60
var audioAcc: int64 = 0
var lastAudioTime = getMonoTime()

window.onFrame = proc() =
  ss.pump()  # always reclaim, even when stopped

  # Pace + generate audio only when a song is active. Use wall time acc like play.nim.
  let nowT = getMonoTime()
  audioAcc += (nowT - lastAudioTime).inNanoseconds
  lastAudioTime = nowT

  if activeApu != nil:
    const SamplesPerFrame = SampleRate div 60
    let dueNs = TargetFrameNs
    if audioAcc > dueNs * 4:
      audioAcc = dueNs * 4
    var framesToGen = 0
    while audioAcc >= dueNs and framesToGen < 4:
      audioAcc -= dueNs
      inc framesToGen
    for _ in 0 ..< framesToGen:
      var pcm = newSeq[uint8](SamplesPerFrame * 4)
      for i in 0 ..< SamplesPerFrame:
        let (l, r) = activeApu.runSample()
        let off = i * 4
        pcm[off + 0] = (l and 0xFF).uint8
        pcm[off + 1] = ((l shr 8) and 0xFF).uint8
        pcm[off + 2] = (r and 0xFF).uint8
        pcm[off + 3] = ((r shr 8) and 0xFF).uint8
        inc sampleCounter
        if sampleCounter mod SampleRate == 0:
          activeApu.portsIn[0] = (currentSong and 0xFF).uint8
      ss.queueData(pcm)

  sk.beginUI(window, window.size)
  sk.clearScreen(parseHtmlColor("#1D1D1D").rgbx)

  # Header
  sk.at = vec2(16, 16)
  h1text("EarthBound Jukebox")

  # Now playing status
  sk.at = vec2(16, 60)
  text(if currentSong > 0: &"Now playing: Song {currentSong:03d}" else: "Stopped")

  # Stop button (list click starts playback)
  sk.at = vec2(16, 90)
  button("Stop"):
    activeApu = nil
    currentSong = 0

  # Scrollable song list via frame (auto scrollbars when content exceeds).
  # Each entry is a clickable button; click starts the song immediately.
  sk.at = vec2(16, 130)
  frame("songs", vec2(16, 130), vec2(488, 470)):
    sk.at = sk.pos + vec2(8, 8)
    for i, sid in songIds:
      let lbl = songLabels[i]
      button(lbl):
        startSong(sid)

  sk.endUi()
  window.swapBuffers()

while not window.closeRequested:
  pollEvents()

# Clean shutdown (reached on window close).
ss.close()
slappyClose()
