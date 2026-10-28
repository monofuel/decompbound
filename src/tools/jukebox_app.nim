import
  std/[math, monotimes, os, parseopt, strformat, strutils, times],
  opengl, paddy, pixie, slappy, windy,
  ../decompbound/[jukebox_controls, jukebox_view, music_player],
  ./glblit

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  UiFrameNs = 1_000_000_000'i64 div 30
  MaxAudioDelayNs = 100_000_000'i64
  AudioChunkFrames = 512
  AudioPrefillFrames = MusicSampleRate div 20
  NanosecondsPerSecond = 1_000_000_000'i64
  Help = """Pocket Jukebox - EarthBound music from your own ROM.
Usage: bin/jukebox [ROM] [--rom:PATH] [--song:N] [--fullscreen] [--mute]
  --frames:N   Exit after N UI frames (for smoke checks).
  --trace      Print control actions and playback state.
Mouse: click a track to play; wheel browses; buttons control playback/volume.
Keyboard: Up/Down browse, PageUp/PageDown page, Home/End first/last.
  Enter plays selected; Space plays/pauses; S stops; Left/Right skip tracks.
  -/+ changes volume; Escape exits.
Paddy: D-pad or left stick Up/Down browses; bottom face button plays.
  Start plays/pauses; right face button stops; L1/R1 skip tracks.
  D-pad Left/Right changes volume. Controllers can connect during playback.
  L2/R2 pages the list; Start+Select exits.
Music continues while the window is in the background. Tracks loop as in game.
"""

type
  JukeboxApp = object
    player: MusicPlayer
    selection: TrackSelection
    stream: StreamingSource
    volume: int
    level: float32
    audioCarry: int64
    lastAudio: MonoTime
    audioStarted: bool
    underruns: int
    muted, trace, quitting: bool

proc resetAudio(app: var JukeboxApp) =
  ## Drop queued audio immediately on song changes, stop, or pause transitions.
  if app.stream != nil: app.stream.flush()
  app.audioCarry = 0
  app.lastAudio = getMonoTime()
  app.level = 0
  app.audioStarted = false

proc perform(app: var JukeboxApp, action: JukeboxAction) =
  ## Apply every input method through the same navigation and playback actions.
  case action
  of MoveUp, MoveDown, PageUp, PageDown, GoFirst, GoLast:
    app.selection.navigate(action)
  of PlaySelected:
    app.resetAudio()
    app.player.startTrack(app.player.library.trackIds[app.selection.index])
    app.audioCarry = AudioPrefillFrames.int64 * NanosecondsPerSecond
    app.lastAudio = getMonoTime()
  of TogglePlayback:
    if app.player.state == Stopped:
      app.perform(PlaySelected)
    else:
      app.resetAudio()
      app.player.togglePause()
      if app.player.state == Playing:
        app.audioCarry = AudioPrefillFrames.int64 * NanosecondsPerSecond
  of StopPlayback:
    app.resetAudio()
    app.player.stop()
  of PreviousTrack, NextTrack:
    let
      tracks = app.player.library.trackIds
      current = if app.player.songId > 0: tracks.find(app.player.songId) else: app.selection.index
      direction = if action == PreviousTrack: -1 else: 1
      index = (current + direction + tracks.len) mod tracks.len
    app.selection.selectIndex(index)
    app.perform(PlaySelected)
  of Quieter, Louder:
    app.volume = clamp(app.volume + (if action == Quieter: -VolumeStep else: VolumeStep), 0, 100)
    if not app.muted: listener.gain = app.volume.float32 / 100
  of QuitPlayer:
    app.quitting = true
  if app.trace:
    echo &"action={action} selected={app.player.library.trackIds[app.selection.index]} song={app.player.songId} state={app.player.state} volume={app.volume}"

proc pumpAudio(app: var JukeboxApp, pcm: var seq[int16], bytes: var seq[uint8]) =
  ## Generate bounded wall-clock audio independently of UI rendering and focus.
  let now = getMonoTime()
  if app.stream != nil: app.stream.pump()
  if app.player.state != Playing:
    app.lastAudio = now
    return
  let elapsed = min((now - app.lastAudio).inNanoseconds, MaxAudioDelayNs)
  app.lastAudio = now
  if app.stream != nil and app.audioStarted and not app.stream.playing:
    inc app.underruns
    app.audioCarry += AudioPrefillFrames.int64 * NanosecondsPerSecond
  app.audioCarry += elapsed * MusicSampleRate
  let frames = int(app.audioCarry div NanosecondsPerSecond)
  if frames < AudioChunkFrames: return
  app.audioCarry -= frames.int64 * NanosecondsPerSecond
  app.player.renderPcm(frames, pcm)
  var sumSquares = 0.0
  bytes.setLen(pcm.len * 2)
  for i, sample in pcm:
    let bits = cast[uint16](sample)
    bytes[i * 2] = (bits and 0xFF).uint8
    bytes[i * 2 + 1] = (bits shr 8).uint8
    sumSquares += sample.float64 * sample.float64
  if pcm.len > 0:
    let level = sqrt(sumSquares / pcm.len.float64) / 32768 * 8
    app.level = max(app.level * 0.8, min(1.0, level).float32)
  if app.stream != nil:
    app.stream.queueData(bytes)
    app.audioStarted = true

proc main() =
  ## Run a music-only player with a local ROM, shared audio engine, and three input methods.
  var
    romPath = DefaultRom
    initialSong = 0
    frameLimit = 0
    muted, fullscreen, trace = false
  for kind, key, value in getopt():
    case kind
    of cmdArgument: romPath = key
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": stdout.write(Help); return
      of "rom":
        if value.len == 0: raise newException(ValueError, "Use --rom:PATH.")
        romPath = value
      of "song":
        initialSong = parseInt(value)
        if initialSong notin 1 .. SongCount: raise newException(ValueError, "Song must be 1..191.")
      of "frames":
        frameLimit = parseInt(value)
        if frameLimit <= 0: raise newException(ValueError, "Frame limit must be positive.")
      of "mute": muted = true
      of "fullscreen": fullscreen = true
      of "trace": trace = true
      else: raise newException(ValueError, "Unknown option: " & key)
    of cmdEnd: discard
  let
    library = loadMusicLibrary(romPath)
    view = newJukeboxView()
  if library.trackIds.len == 0: raise newException(ValueError, "ROM has no music tracks.")
  var app = JukeboxApp(player: newMusicPlayer(library),
    selection: TrackSelection(count: library.trackIds.len), volume: 80,
    muted: muted, trace: trace, lastAudio: getMonoTime())
  defer: app.player.stop()
  if not muted:
    slappyInit()
  defer:
    if not muted: slappyClose()
  if not muted:
    app.stream = newStreamingSource(frequency = MusicSampleRate, channels = 2, bits = 16)
    listener.gain = app.volume.float32 / 100
  defer:
    if app.stream != nil: app.stream.close()
  let blit = initGlBlit("Pocket Jukebox", ViewWidth, ViewHeight, scale = 1,
    fullscreen = fullscreen, vsync = false)
  let window = blit.window
  defer:
    glDeleteBuffers(1, unsafeAddr blit.posBuffer)
    glDeleteBuffers(1, unsafeAddr blit.uvBuffer)
    glDeleteTextures(1, unsafeAddr blit.textureId)
    glDeleteProgram(blit.program)
    window.close()
  initGamepads()
  defer: closeGamepads()
  if initialSong > 0:
    if initialSong notin library.trackIds: raise newException(ValueError, "Unused song id.")
    app.selection.selectIndex(library.trackIds.find(initialSong))
    app.perform(PlaySelected)
  var
    input: JukeboxInput
    pcm: seq[int16]
    bytes: seq[uint8]
    nextUi = getMonoTime()
    frameCount = 0
  echo &"Pocket Jukebox: {library.trackIds.len} tracks; audio={not muted}."
  while not app.quitting:
    pollEvents()
    if window.closeRequested: break
    let
      now = getMonoTime()
      pads = pollGamepads()
      mouse = viewPoint(vec2(window.mousePos.x.float32, window.mousePos.y.float32),
        window.size.x.int, window.size.y.int)
    if window.focused and not window.minimized:
      var keys: set[Button]
      for key in Button:
        if window.buttonDown[key] or window.buttonPressed[key]: keys.incl(key)
      for action in input.update(keyboardActions(keys) + gamepadActions(pads), now.ticks div 1_000_000):
        app.perform(action)
      if window.scrollDelta.y != 0:
        app.perform(if window.scrollDelta.y > 0: MoveDown else: MoveUp)
      if window.buttonPressed[MouseLeft]:
        let target = mouseTarget(mouse, app.selection)
        if target.trackIndex >= 0:
          app.selection.selectIndex(target.trackIndex)
          app.perform(PlaySelected)
        for action in target.actions: app.perform(action)
    else: input.reset()
    app.pumpAudio(pcm, bytes)
    if now >= nextUi and not window.minimized:
      let image = view.render(JukeboxDisplay(selection: app.selection,
        tracks: library.trackIds, songId: app.player.songId,
        playing: app.player.state == Playing, paused: app.player.state == Paused,
        elapsedSeconds: int(app.player.renderedFrames div MusicSampleRate),
        volume: app.volume, level: app.level, hover: mouse, controllerCount: pads.len))
      blit.blit(image)
      inc frameCount
      nextUi = getMonoTime() + initDuration(nanoseconds = UiFrameNs)
      if frameLimit > 0 and frameCount >= frameLimit: break
    sleep(2)
  if app.trace: echo &"audioUnderruns={app.underruns} renderedFrames={app.player.renderedFrames}"

when isMainModule:
  main()
