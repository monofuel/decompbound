import
  std/[math, monotimes, os, parseopt, strformat, strutils, times],
  opengl, paddy, pixie, windy,
  ../decompbound/[jukebox_controls, jukebox_view, music_output, music_player],
  ./glblit

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  UiFrameNs = 1_000_000_000'i64 div 30
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
    output: MusicOutput
    selection: TrackSelection
    trace, quitting: bool

proc perform(app: var JukeboxApp, action: JukeboxAction) =
  ## Apply every input method through the same navigation and playback actions.
  case action
  of MoveUp, MoveDown, PageUp, PageDown, GoFirst, GoLast:
    app.selection.navigate(action)
  of PlaySelected:
    app.output.start(app.output.player.library.trackIds[app.selection.index])
  of TogglePlayback:
    if app.output.player.state == Stopped:
      app.perform(PlaySelected)
    else:
      app.output.setPaused(app.output.player.state == Playing)
  of StopPlayback:
    app.output.stop()
  of PreviousTrack, NextTrack:
    let
      tracks = app.output.player.library.trackIds
      current = if app.output.player.songId > 0: tracks.find(app.output.player.songId) else: app.selection.index
      direction = if action == PreviousTrack: -1 else: 1
      index = (current + direction + tracks.len) mod tracks.len
    app.selection.selectIndex(index)
    app.perform(PlaySelected)
  of Quieter, Louder:
    app.output.setPercent(clamp(
      app.output.volume + (if action == Quieter: -VolumeStep else: VolumeStep), 0, 100))
  of QuitPlayer:
    app.quitting = true
  if app.trace:
    echo &"action={action} selected={app.output.player.library.trackIds[app.selection.index]} song={app.output.player.songId} state={app.output.player.state} volume={app.output.volume}"

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
  let player = newMusicPlayer(library)
  defer: player.stop()
  var app = JukeboxApp(
    output: openMusicOutput(player, enabled = not muted, trace = trace),
    selection: TrackSelection(count: library.trackIds.len),
    trace: trace)
  defer: app.output.close()
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
    app.output.pump()
    if now >= nextUi and not window.minimized:
      let image = view.render(JukeboxDisplay(selection: app.selection,
        tracks: library.trackIds, songId: app.output.player.songId,
        playing: app.output.player.state == Playing, paused: app.output.player.state == Paused,
        elapsedSeconds: int(app.output.player.renderedFrames div MusicSampleRate),
        volume: app.output.volume, volumeMuted: app.output.muted or muted,
        level: app.output.level, hover: mouse, controllerCount: pads.len))
      blit.blit(image)
      inc frameCount
      nextUi = getMonoTime() + initDuration(nanoseconds = UiFrameNs)
      if frameLimit > 0 and frameCount >= frameLimit: break
    sleep(2)
  if app.trace: echo &"audioUnderruns={app.output.underruns} renderedFrames={app.output.player.renderedFrames}"


when isMainModule:
  main()
