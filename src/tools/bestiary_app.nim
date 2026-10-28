import
  std/[monotimes, os, parseopt, strformat, strutils, times, unicode],
  paddy, windy,
  ../decompbound/[bestiary, bestiary_browser, bestiary_scene, bestiary_view, music_output, music_player],
  ./glblit

type
  BestiaryApp = object
    browser: BestiaryBrowser
    output: MusicOutput
    window: GlBlit
    quitting, trace: bool

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  UiFrameNs = 1_000_000_000'i64 div 60
  VolumeStep = 5
  Help = """Pocket Bestiary - enemy portraits, stats and music from your own ROM.
Usage: bin/bestiary [ROM] [--rom:PATH] [--enemy:N] [--fullscreen] [--mute]
  --mute      Disable audio-device initialization for visual-only use.
  --frames:N  Exit after N displayed frames for a bounded smoke check.
  --trace     Print input, selection, theme and playback diagnostics.
Up/Down: enemy. PageUp/PageDown: page. Home/End: first/last match.
Left/Right: background variant. Space: pause both. Enter: restart and play.
R: reset both, preserving pause. M: music mute. Minus/plus: volume.
Slash/Ctrl+F: search. Escape/Enter leave search; Escape otherwise exits.
F11: fullscreen. Mouse: search, enemies, pages and transport controls.
Paddy: Up/Down or stick: enemy; L2/R2: page; L1/R1: background.
Start: pause both; A: restart; B: reset; X: mute; Y: fullscreen.
D-pad Left/Right: volume. Start+Select: quit. Music continues unfocused.
Music follows the selected enemy's own theme; background variants do not change it.
"""

proc traceState(app: BestiaryApp, action: string) =
  ## Report observable actions without requiring screenshots or audio captures.
  if app.trace:
    let id = if app.browser.hasSelection: app.browser.currentEnemy.id else: 0
    echo &"action={action} enemy={id} variant={app.browser.variantIndex + 1} frame={app.browser.frame} paused={app.browser.paused} song={app.browser.activeSong} volume={app.output.volume} muted={app.output.muted} musicFrame={app.output.player.renderedFrames} playerState={app.output.player.state}"

proc perform(app: var BestiaryApp, action: BestiaryAction, nowMs: int64) =
  ## Route all input devices through the same transport and navigation actions.
  case action
  of QuitBestiary: app.quitting = true
  of Fullscreen: app.window.window.fullscreen = not app.window.window.fullscreen
  of ToggleMusicMute:
    if app.output.audioEnabled: app.output.setMuted(not app.output.muted)
  of VolumeDown: app.output.setPercent(max(0, app.output.volume - VolumeStep))
  of VolumeUp: app.output.setPercent(min(100, app.output.volume + VolumeStep))
  else: app.browser.perform(action, nowMs)
  app.traceState($action)

proc syncTheme(app: var BestiaryApp, nowMs: int64) =
  ## Execute only settled theme changes and apply the coupled pause before pumping audio.
  for command in app.browser.updateTheme(nowMs):
    case command.kind
    of StopTheme:
      app.output.stop()
      if app.trace: echo "theme=stop"
    of StartTheme:
      app.output.start(command.songId)
      app.output.setPaused(app.browser.paused)
      if app.trace:
        echo &"theme=start song={command.songId} paused={app.browser.paused} playerState={app.output.player.state}"
  app.output.setPaused(app.browser.paused)

proc search(app: var BestiaryApp, query: string, nowMs: int64) =
  ## Change the search and report the visible result count.
  app.browser.setQuery(query, nowMs)
  if app.trace: echo &"query={query} results={app.browser.visible.len}"

proc main() =
  ## Run the single-window bestiary with native graphics and shared ROM-backed music.
  var
    romPath = DefaultRom
    initialEnemy = 1
    frameLimit = 0
    fullscreen, muted, trace = false
  for kind, key, value in getopt():
    case kind
    of cmdArgument: romPath = key
    of cmdShortOption, cmdLongOption:
      case key
      of "help", "h": stdout.write(Help); return
      of "rom":
        if value.len == 0: raise newException(ValueError, "Use --rom:PATH.")
        romPath = value
      of "enemy": initialEnemy = parseInt(value)
      of "frames":
        frameLimit = parseInt(value)
        if frameLimit <= 0: raise newException(ValueError, "Frame limit must be positive.")
      of "fullscreen": fullscreen = true
      of "mute": muted = true
      of "trace": trace = true
      else: raise newException(ValueError, "Unknown option: " & key)
    of cmdEnd: discard
  if initialEnemy notin EnemyMinId .. EnemyMaxId:
    raise newException(ValueError, "Enemy id is outside the supported catalog.")
  let
    library = loadBestiaryLibrary(romPath)
    view = newBestiaryView()
    scene = newBestiaryScene()
  var app = BestiaryApp(browser: newBestiaryBrowser(library), trace: trace)
  app.browser.selectEnemy(initialEnemy - EnemyMinId)
  app.window = initGlBlit("Pocket Bestiary", BestiaryWidth, BestiaryHeight,
    scale = 1, vsync = false, fullscreen = fullscreen)
  defer: app.window.close()
  app.output = openMusicOutput(newMusicPlayer(library.music), enabled = not muted, trace = trace)
  defer: app.output.close()
  initGamepads()
  defer: closeGamepads()
  var
    input: BestiaryInput
    typed: seq[Rune]
    blockedKeys: set[Button]
    previous = getMonoTime()
    nextFrame = previous
    frames = 0
  app.window.window.runeInputEnabled = true
  app.window.window.onRune = proc(rune: Rune) =
    ## Buffer text events until the frame can resolve search focus.
    typed.add rune
  echo &"Pocket Bestiary: {library.enemies.len} enemies; automatic enemy themes; audio={not muted}."
  while not app.quitting:
    pollEvents()
    let window = app.window.window
    if window.closeRequested: break
    let
      now = getMonoTime()
      nowMs = now.ticks div 1_000_000
      pads = pollGamepads()
      point = bestiaryPoint(vec2(window.mousePos.x.float32, window.mousePos.y.float32), window.size.x.int, window.size.y.int)
      wasSearching = app.browser.searching
    app.browser.advance((now - previous).inNanoseconds)
    previous = now
    if window.focused and not window.minimized:
      var rawKeys: set[Button]
      for key in Button:
        if window.buttonDown[key] or window.buttonPressed[key]: rawKeys.incl(key)
      blockedKeys = blockedKeys * rawKeys
      let keys = rawKeys - blockedKeys
      if wasSearching:
        if window.buttonPressed[KeyA] and (KeyLeftControl in keys or KeyRightControl in keys):
          app.search("", nowMs)
        if window.buttonPressed[KeyBackspace] and app.browser.query.len > 0:
          app.search(app.browser.query[0 ..< app.browser.query.len - 1], nowMs)
        for rune in typed:
          if rune.int in 32..126: app.search(app.browser.query & $char(rune.int), nowMs)
      for action in input.update(bestiary_browser.keyboardActions(keys, wasSearching) +
          bestiary_browser.gamepadActions(pads), nowMs): app.perform(action, nowMs)
      if window.scrollDelta.y != 0:
        app.perform(if window.scrollDelta.y > 0: EnemyDown else: EnemyUp, nowMs)
      if window.buttonPressed[MouseLeft]:
        let target = mouseTarget(point, app.browser)
        app.browser.searching = target.search
        if target.row >= 0:
          app.browser.selectEnemy(target.row, nowMs)
          app.traceState("SelectEnemy")
        for action in target.actions: app.perform(action, nowMs)
      if wasSearching != app.browser.searching: blockedKeys = blockedKeys + rawKeys
    else:
      input.reset()
      blockedKeys = {}
    typed.setLen(0)
    app.syncTheme(nowMs)
    app.output.pump()
    if now >= nextFrame and not window.minimized:
      let display = BestiaryDisplay(volume: app.output.volume, muted: app.output.muted,
        audioEnabled: app.output.audioEnabled, controllers: pads.len)
      app.window.blit(view.render(app.browser, scene.render(app.browser), display, point))
      inc frames
      nextFrame = getMonoTime() + initDuration(nanoseconds = UiFrameNs)
      if frameLimit > 0 and frames >= frameLimit: break
    sleep(2)
  if trace: echo &"audioUnderruns={app.output.underruns} renderedFrames={app.output.player.renderedFrames}"

when isMainModule: main()
