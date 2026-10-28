import
  std/[strutils],
  paddy, windy,
  ./[bestiary, battle_bg_catalog, jukebox_controls]

type
  BestiaryAction* = enum
    EnemyUp, EnemyDown, EnemyPageUp, EnemyPageDown, EnemyFirst, EnemyLast,
    PreviousBackground, NextBackground, PauseBoth, RestartBoth, ResetBoth,
    ToggleMusicMute, VolumeDown, VolumeUp, Fullscreen, FocusSearch, LeaveSearch, QuitBestiary
  ThemeCommandKind* = enum
    StopTheme, StartTheme
  ThemeCommand* = object
    kind*: ThemeCommandKind
    songId*: int
  BestiaryBrowser* = ref object
    library*: BestiaryLibrary
    selection*: TrackSelection
    visible*: seq[int]
    query*: string
    searching*, paused*: bool
    variantIndex*: int
    frame*: int64
    activeSong*: int
    rememberedId: int
    remainder: int64
    pendingSong: int
    themeDue: int64
    forceRestart: bool
  BestiaryInput* = object
    previous: set[BestiaryAction]
    repeatAt: array[BestiaryAction, int64]

const
  ThemeDelayMs* = 150'i64
  InitialRepeatMs = 350'i64
  RepeatMs = 85'i64
  ClockDivisor = 1_000_000_000'i64
  AnimationHz = 60'i64
  StickThreshold = 0.5'f32

proc hasSelection*(browser: BestiaryBrowser): bool =
  ## Report whether the current search has a selectable enemy.
  browser.visible.len > 0

proc currentEnemy*(browser: BestiaryBrowser): EnemyRecord =
  ## Return the selected supported ROM record, rejecting an empty search.
  if not browser.hasSelection: raise newException(ValueError, "No enemy matches this search.")
  browser.library.enemies[browser.visible[browser.selection.index]]

proc variants*(browser: BestiaryBrowser): seq[BackgroundVariant] =
  ## Return the selected enemy's existing encounter background variants.
  if not browser.hasSelection: return
  let index = browser.library.catalog.enemyIndex(browser.currentEnemy.id)
  if index >= 0: result = browser.library.catalog.enemies[index].variants

proc playableSong*(browser: BestiaryBrowser): int =
  ## Resolve the enemy's own assigned playable theme, or zero for silence.
  if not browser.hasSelection: return 0
  let song = browser.currentEnemy.musicId
  if song in browser.library.music.trackIds: song else: 0

proc resetAnimation*(browser: BestiaryBrowser) =
  ## Reset the visual clock without changing global pause.
  browser.frame = 0
  browser.remainder = 0

proc scheduleTheme(browser: BestiaryBrowser, nowMs: int64) =
  ## Coalesce different-song selection changes without disturbing a shared song.
  let song = browser.playableSong
  if song != browser.pendingSong:
    browser.pendingSong = song
    browser.themeDue = nowMs + ThemeDelayMs

proc selectEnemy*(browser: BestiaryBrowser, index: int, nowMs = 0'i64) =
  ## Select a visible row immediately while preserving mute, pause and shared music.
  if not browser.hasSelection: return
  let oldId = browser.currentEnemy.id
  browser.selection.selectIndex(index)
  browser.rememberedId = browser.currentEnemy.id
  if browser.currentEnemy.id != oldId:
    browser.variantIndex = 0
    browser.resetAnimation()
  browser.scheduleTheme(nowMs)

proc setQuery*(browser: BestiaryBrowser, query: string, nowMs = 0'i64) =
  ## Filter by name substring or numeric id, preserving the selected id when possible.
  let oldId = if browser.hasSelection: browser.currentEnemy.id else: browser.rememberedId
  browser.query = query
  browser.visible.setLen(0)
  let needle = query.strip.toLowerAscii
  for index, enemy in browser.library.enemies:
    if needle.len == 0 or needle in enemy.name.toLowerAscii or needle == $enemy.id or needle == "#" & $enemy.id:
      browser.visible.add index
  browser.selection = TrackSelection(count: browser.visible.len)
  if browser.hasSelection:
    var selected = 0
    for index, source in browser.visible:
      if browser.library.enemies[source].id == oldId: selected = index
    browser.selection.selectIndex(selected)
    browser.rememberedId = browser.currentEnemy.id
  if not browser.hasSelection or browser.currentEnemy.id != oldId:
    browser.variantIndex = 0
    browser.resetAnimation()
  browser.scheduleTheme(nowMs)

proc newBestiaryBrowser*(library: BestiaryLibrary): BestiaryBrowser =
  ## Start at the first supported enemy with automatic music and a fresh visual clock.
  if library == nil or library.enemies.len == 0:
    raise newException(ValueError, "Bestiary library has no enemy records.")
  result = BestiaryBrowser(library: library, pendingSong: -1)
  result.setQuery("")
  result.themeDue = 0

proc perform*(browser: BestiaryBrowser, action: BestiaryAction, nowMs = 0'i64) =
  ## Apply navigation and coupled transport consistently for all input devices.
  case action
  of EnemyUp: browser.selectEnemy(browser.selection.index - 1, nowMs)
  of EnemyDown: browser.selectEnemy(browser.selection.index + 1, nowMs)
  of EnemyPageUp: browser.selectEnemy(browser.selection.index - VisibleTracks, nowMs)
  of EnemyPageDown: browser.selectEnemy(browser.selection.index + VisibleTracks, nowMs)
  of EnemyFirst: browser.selectEnemy(0, nowMs)
  of EnemyLast: browser.selectEnemy(browser.selection.count - 1, nowMs)
  of PreviousBackground, NextBackground:
    let count = browser.variants.len
    if count > 0:
      let delta = if action == PreviousBackground: -1 else: 1
      browser.variantIndex = (browser.variantIndex + count + delta) mod count
      browser.resetAnimation()
  of PauseBoth:
    browser.paused = not browser.paused
    browser.remainder = 0
  of RestartBoth, ResetBoth:
    browser.resetAnimation()
    if action == RestartBoth: browser.paused = false
    browser.forceRestart = true
    browser.themeDue = nowMs
  of FocusSearch: browser.searching = true
  of LeaveSearch: browser.searching = false
  of ToggleMusicMute, VolumeDown, VolumeUp, Fullscreen, QuitBestiary: discard

proc updateTheme*(browser: BestiaryBrowser, nowMs: int64): seq[ThemeCommand] =
  ## Stop stale music immediately and start only the newest settled selection.
  if browser.activeSong != browser.pendingSong or browser.forceRestart:
    if browser.activeSong != 0:
      result.add ThemeCommand(kind: StopTheme)
      browser.activeSong = 0
    if browser.pendingSong > 0 and nowMs >= browser.themeDue:
      result.add ThemeCommand(kind: StartTheme, songId: browser.pendingSong)
      browser.activeSong = browser.pendingSong
    browser.forceRestart = false

proc advance*(browser: BestiaryBrowser, elapsedNs: int64) =
  ## Advance a focus-independent rational visual clock while the app is playing.
  if elapsedNs < 0: raise newException(ValueError, "Negative animation clock delta.")
  if browser.paused or not browser.hasSelection: return
  if elapsedNs > (high(int64) - browser.remainder) div AnimationHz:
    raise newException(ValueError, "Animation clock delta is too large.")
  let ticks = elapsedNs * AnimationHz + browser.remainder
  browser.frame += ticks div ClockDivisor
  browser.remainder = ticks mod ClockDivisor

proc keyboardActions*(keys: set[Button], searching = false): set[BestiaryAction] =
  ## Protect typed search text from transport shortcuts while retaining navigation.
  for (key, action) in [(KeyUp, EnemyUp), (KeyDown, EnemyDown),
      (KeyPageUp, EnemyPageUp), (KeyPageDown, EnemyPageDown),
      (KeyHome, EnemyFirst), (KeyEnd, EnemyLast), (KeyF11, Fullscreen)]:
    if key in keys: result.incl(action)
  if searching:
    if KeyEscape in keys or KeyEnter in keys: result.incl(LeaveSearch)
  else:
    for (key, action) in [(KeyLeft, PreviousBackground), (KeyRight, NextBackground),
        (KeySpace, PauseBoth), (KeyEnter, RestartBoth), (KeyR, ResetBoth),
        (KeyM, ToggleMusicMute), (KeyMinus, VolumeDown), (KeyEqual, VolumeUp),
        (KeyEscape, QuitBestiary), (KeySlash, FocusSearch)]:
      if key in keys: result.incl(action)
  if KeyF in keys and (KeyLeftControl in keys or KeyRightControl in keys):
    result.incl(FocusSearch)

proc gamepadActions*(pads: openArray[Gamepad]): set[BestiaryAction] =
  ## Read Paddy's public positional controls and consume the exit chord as one action.
  for pad in pads:
    if pad.button(GamepadStart) and pad.button(GamepadSelect):
      result.incl(QuitBestiary)
      continue
    for (button, action) in [(GamepadUp, EnemyUp), (GamepadDown, EnemyDown),
        (GamepadL2, EnemyPageUp), (GamepadR2, EnemyPageDown),
        (GamepadL1, PreviousBackground), (GamepadR1, NextBackground),
        (GamepadStart, PauseBoth), (GamepadA, RestartBoth), (GamepadB, ResetBoth),
        (GamepadX, ToggleMusicMute), (GamepadY, Fullscreen),
        (GamepadLeft, VolumeDown), (GamepadRight, VolumeUp)]:
      if pad.button(button): result.incl(action)
    if pad.axis(GamepadLStickY) < -StickThreshold: result.incl(EnemyUp)
    if pad.axis(GamepadLStickY) > StickThreshold: result.incl(EnemyDown)

proc update*(input: var BestiaryInput, held: set[BestiaryAction], nowMs: int64): seq[BestiaryAction] =
  ## Debounce transport and repeat bounded navigation and volume presses.
  var actions = held
  if EnemyUp in actions and EnemyDown in actions:
    actions.excl(EnemyUp)
    actions.excl(EnemyDown)
  for action in actions:
    if action notin input.previous:
      result.add(action)
      input.repeatAt[action] = nowMs + InitialRepeatMs
    elif action in {EnemyUp, EnemyDown, EnemyPageUp, EnemyPageDown, VolumeDown, VolumeUp} and nowMs >= input.repeatAt[action]:
      result.add(action)
      input.repeatAt[action] = nowMs + RepeatMs
  input.previous = actions

proc reset*(input: var BestiaryInput) =
  ## Release held inputs when focus leaves the window.
  input = BestiaryInput()
