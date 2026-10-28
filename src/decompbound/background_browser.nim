import
  paddy, windy,
  ./[battle_bg_catalog, jukebox_controls]

const
  SpeedQuarters* = [1, 2, 4, 8]
  SpeedLabels* = ["0.25x", "0.5x", "1x", "2x"]
  AnimationHz = 60'i64
  ClockDivisor = 4_000_000_000'i64
  InitialRepeatMs = 350'i64
  RepeatMs = 85'i64
  StickThreshold = 0.5'f32

type
  BackgroundAction* = enum
    EnemyUp, EnemyDown, EnemyPageUp, EnemyPageDown, EnemyFirst, EnemyLast,
    VariantPrevious, VariantNext, ToggleAnimation, RestartAnimation,
    ResetAnimation, StepAnimation, Slower, Faster, ToggleFullscreen,
    ShowPreview, QuitBrowser
  BackgroundBrowser* = ref object
    catalog*: BackgroundCatalog
    selection*: TrackSelection
    variantIndex*: int
    frame*: int64
    paused*: bool
    speedIndex*: int
    remainder: int64
  BackgroundInput* = object
    previous: set[BackgroundAction]
    repeatAt: array[BackgroundAction, int64]

proc currentEnemy*(browser: BackgroundBrowser): EnemyBackgroundEntry =
  ## Return the selected enemy including its ROM-defined background variants.
  browser.catalog.enemies[browser.selection.index]

proc hasBackground*(browser: BackgroundBrowser): bool =
  ## Report whether this enemy has an associated encounter configuration.
  browser.currentEnemy.variants.len > 0

proc currentVariant*(browser: BackgroundBrowser): BackgroundVariant =
  ## Return the selected configuration, rejecting enemies without a mapping.
  if not browser.hasBackground:
    raise newException(ValueError, "Selected enemy has no mapped encounter background.")
  browser.currentEnemy.variants[browser.variantIndex]

proc resetAnimation*(browser: BackgroundBrowser) =
  ## Return to frame zero while preserving pause and playback speed.
  browser.frame = 0
  browser.remainder = 0

proc selectEnemy*(browser: BackgroundBrowser, index: int) =
  ## Select an enemy immediately, resetting its variant and animation.
  let old = browser.selection.index
  browser.selection.selectIndex(index)
  if browser.selection.index != old:
    browser.variantIndex = 0
    browser.resetAnimation()

proc newBackgroundBrowser*(catalog: BackgroundCatalog): BackgroundBrowser =
  ## Start at the first mapped enemy at normal speed.
  if catalog == nil or catalog.enemies.len == 0:
    raise newException(ValueError, "Background catalog has no enemy records.")
  result = BackgroundBrowser(catalog: catalog,
    selection: TrackSelection(count: catalog.enemies.len), speedIndex: 2)
  for i, enemy in catalog.enemies:
    if enemy.variants.len > 0:
      result.selectEnemy(i)
      break

proc perform*(browser: BackgroundBrowser, action: BackgroundAction) =
  ## Apply shared mouse, keyboard, and Paddy actions to the browser state.
  let old = browser.selection.index
  case action
  of EnemyUp: browser.selectEnemy(old - 1)
  of EnemyDown: browser.selectEnemy(old + 1)
  of EnemyPageUp: browser.selectEnemy(old - VisibleTracks)
  of EnemyPageDown: browser.selectEnemy(old + VisibleTracks)
  of EnemyFirst: browser.selectEnemy(0)
  of EnemyLast: browser.selectEnemy(browser.selection.count - 1)
  of VariantPrevious, VariantNext:
    if browser.hasBackground:
      let
        count = browser.currentEnemy.variants.len
        delta = if action == VariantPrevious: -1 else: 1
      browser.variantIndex = (browser.variantIndex + delta + count) mod count
      browser.resetAnimation()
  of ToggleAnimation:
    browser.paused = not browser.paused
    browser.remainder = 0
  of RestartAnimation:
    browser.resetAnimation()
    browser.paused = false
  of ResetAnimation: browser.resetAnimation()
  of StepAnimation:
    if browser.paused and browser.hasBackground: inc browser.frame
  of Slower, Faster:
    let delta = if action == Slower: -1 else: 1
    browser.speedIndex = clamp(browser.speedIndex + delta, 0, SpeedQuarters.high)
    browser.remainder = 0
  of ToggleFullscreen, ShowPreview, QuitBrowser: discard

proc advance*(browser: BackgroundBrowser, elapsedNs: int64) =
  ## Advance a rational 60 Hz clock independently of drawing and window focus.
  if elapsedNs < 0: raise newException(ValueError, "Negative animation clock delta.")
  if browser.paused or not browser.hasBackground: return
  if elapsedNs > (high(int64) - browser.remainder) div (AnimationHz * SpeedQuarters[browser.speedIndex]):
    raise newException(ValueError, "Animation clock delta is too large.")
  let ticks = elapsedNs * AnimationHz * SpeedQuarters[browser.speedIndex] + browser.remainder
  browser.frame += ticks div ClockDivisor
  browser.remainder = ticks mod ClockDivisor

proc keyboardActions*(keys: set[Button]): set[BackgroundAction] =
  ## Read shortcuts from either focused browser window.
  for (key, action) in [
    (KeyUp, EnemyUp), (KeyDown, EnemyDown), (KeyPageUp, EnemyPageUp),
    (KeyPageDown, EnemyPageDown), (KeyHome, EnemyFirst), (KeyEnd, EnemyLast),
    (KeyLeft, VariantPrevious), (KeyRight, VariantNext), (KeySpace, ToggleAnimation),
    (KeyEnter, RestartAnimation), (KeyR, ResetAnimation), (KeyPeriod, StepAnimation),
    (KeyMinus, Slower), (KeyEqual, Faster), (KeyF11, ToggleFullscreen),
    (KeyP, ShowPreview), (KeyEscape, QuitBrowser)
  ]:
    if key in keys: result.incl(action)

proc gamepadActions*(pads: openArray[Gamepad]): set[BackgroundAction] =
  ## Map Paddy's public positional controls without direct device access.
  for pad in pads:
    for (button, action) in [
      (GamepadUp, EnemyUp), (GamepadDown, EnemyDown),
      (GamepadLeft, Slower), (GamepadRight, Faster),
      (GamepadL1, VariantPrevious), (GamepadR1, VariantNext),
      (GamepadL2, EnemyPageUp), (GamepadR2, EnemyPageDown),
      (GamepadA, RestartAnimation), (GamepadB, ResetAnimation),
      (GamepadX, StepAnimation), (GamepadY, ToggleFullscreen),
      (GamepadStart, ToggleAnimation)
    ]:
      if pad.button(button): result.incl(action)
    if pad.axis(GamepadLStickY) < -StickThreshold: result.incl(EnemyUp)
    if pad.axis(GamepadLStickY) > StickThreshold: result.incl(EnemyDown)
    if pad.button(GamepadStart) and pad.button(GamepadSelect):
      result.excl(ToggleAnimation)
      result.incl(QuitBrowser)

proc update*(input: var BackgroundInput, held: set[BackgroundAction], nowMs: int64): seq[BackgroundAction] =
  ## Debounce transport buttons and repeat bounded navigation presses.
  var actions = held
  if EnemyUp in actions and EnemyDown in actions:
    actions.excl(EnemyUp)
    actions.excl(EnemyDown)
  for action in actions:
    if action notin input.previous:
      result.add(action)
      input.repeatAt[action] = nowMs + InitialRepeatMs
    elif action in {EnemyUp, EnemyDown, EnemyPageUp, EnemyPageDown} and nowMs >= input.repeatAt[action]:
      result.add(action)
      input.repeatAt[action] = nowMs + RepeatMs
  input.previous = actions

proc reset*(input: var BackgroundInput) =
  ## Release inputs when neither browser window is focused.
  input = BackgroundInput()
