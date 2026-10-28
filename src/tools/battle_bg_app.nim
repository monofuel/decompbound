import
  std/[monotimes, os, parseopt, strformat, strutils, times],
  paddy, pixie, windy,
  ../decompbound/[background_browser, background_view, battle_bg, battle_bg_catalog],
  ./glblit

const
  ControlsFrameNs = 1_000_000_000'i64 div 30
  PreviewFrameNs = 1_000_000_000'i64 div 60
  Help = """Pocket Backgrounds - enemy-associated EarthBound battle backgrounds.
Usage: bin/battle-bg [ROM] [--rom:PATH] [--enemy:N] [--variant:N] [--fullscreen]
  --frames:N  Exit after N control frames for a bounded smoke check.
  --trace     Print selection, animation, and preview-window diagnostics.
Controls and artwork use separate windows. The preview contains no UI.
Up/Down: enemy. PageUp/PageDown: page. Home/End: first/last enemy.
Left/Right: background variant. Space: pause. Enter: restart and play.
R: reset. Period: step while paused. Minus/plus: speed. F11: preview fullscreen.
P: reopen preview. Escape: exit both windows.
Paddy: Up/Down or left stick browses enemies; L1/R1 changes background.
L2/R2 pages; Left/Right changes speed; bottom button restarts; Start pauses.
Right button resets; X steps; Y opens/toggles fullscreen; Start+Select exits.
Closing the preview keeps controls open. Closing controls exits both windows.
Music is handled by Pocket Jukebox separately. ROM-derived graphics stay local.
"""
  FidelityLabel = "Encounter presets / scripted phases pending"
  # TODO: Reproduce the special VRAM arrangement selected at $C2D205.
  SpecialUploadGroup = 0x1DE

type
  BackgroundApp = object
    browser: BackgroundBrowser
    controls, preview: GlBlit
    previewOpen, quitting, trace: bool
    decoded: BattleBg
    output: Image
    workspace: BackgroundWorkspace
    renderedFrame: int64

proc loadSelection(app: var BackgroundApp) =
  ## Decode a new preset only when the selected enemy or variant changes.
  if app.browser.hasBackground:
    let variant = app.browser.currentVariant
    app.decoded = loadBattleBg(app.browser.catalog.rom, variant.groupIds[0])
    doAssert app.decoded.layerA == variant.layerA and app.decoded.layerB == variant.layerB
  else:
    app.decoded = BattleBg()
  app.renderedFrame = -1

proc showPreview(app: var BackgroundApp) =
  ## Recreate a closed preview without changing selection or animation time.
  if not app.previewOpen:
    app.preview = initGlBlit("Pocket Backgrounds - Preview", ScreenW, ScreenH,
      scale = 3, vsync = false)
    app.previewOpen = true
  app.preview.window.focus()
  if app.trace: echo "preview=open"

proc perform(app: var BackgroundApp, action: BackgroundAction) =
  ## Route every input method through the same application actions.
  let
    oldEnemy = app.browser.selection.index
    oldVariant = app.browser.variantIndex
  case action
  of ToggleFullscreen:
    app.showPreview()
    app.preview.window.fullscreen = not app.preview.window.fullscreen
  of ShowPreview: app.showPreview()
  of QuitBrowser: app.quitting = true
  else: app.browser.perform(action)
  if oldEnemy != app.browser.selection.index or oldVariant != app.browser.variantIndex:
    app.loadSelection()
  if action in {ResetAnimation, RestartAnimation, StepAnimation}: app.renderedFrame = -1
  if app.trace:
    let layers = if app.browser.hasBackground:
      &"{app.browser.currentVariant.layerA}+{app.browser.currentVariant.layerB}" else: "none"
    echo &"action={action} enemy={app.browser.currentEnemy.id} variant={app.browser.variantIndex + 1} layers={layers} frame={app.browser.frame} paused={app.browser.paused} speed={SpeedLabels[app.browser.speedIndex]}"

proc main() =
  ## Run an independent controls window and an integer-scaled background-only preview.
  var
    romPath = DefaultRomPath
    enemyId, variantNumber, frameLimit: int
    fullscreen, trace = false
  for kind, key, value in getopt():
    case kind
    of cmdArgument: romPath = key
    of cmdShortOption, cmdLongOption:
      case key
      of "help", "h": stdout.write(Help); return
      of "rom":
        if value.len == 0: raise newException(ValueError, "Use --rom:PATH.")
        romPath = value
      of "enemy":
        enemyId = parseInt(value)
        if enemyId <= 0: raise newException(ValueError, "Enemy id must be positive.")
      of "variant":
        variantNumber = parseInt(value)
        if variantNumber <= 0: raise newException(ValueError, "Variant is 1-based.")
      of "frames":
        frameLimit = parseInt(value)
        if frameLimit <= 0: raise newException(ValueError, "Frame limit must be positive.")
      of "fullscreen": fullscreen = true
      of "trace": trace = true
      else: raise newException(ValueError, "Unknown option: " & key)
    of cmdEnd: discard
  let
    catalog = loadBackgroundCatalog(romPath)
    view = newBackgroundControlsView()
  var app = BackgroundApp(browser: newBackgroundBrowser(catalog), trace: trace,
    output: newImage(ScreenW, ScreenH), renderedFrame: -1)
  if enemyId > 0:
    let index = catalog.enemyIndex(enemyId)
    if index < 0: raise newException(ValueError, "Enemy id is outside the catalog.")
    app.browser.selectEnemy(index)
  if variantNumber > 0:
    if variantNumber > app.browser.currentEnemy.variants.len:
      raise newException(ValueError, "Variant is outside the selected enemy's backgrounds.")
    app.browser.variantIndex = variantNumber - 1
  app.loadSelection()
  app.controls = initGlBlit("Pocket Backgrounds - Controls", ControlsWidth,
    ControlsHeight, scale = 1, vsync = false)
  defer: app.controls.close()
  app.showPreview()
  defer:
    if app.previewOpen: app.preview.close()
  if fullscreen: app.preview.window.fullscreen = true
  initGamepads()
  defer: closeGamepads()
  var
    input: BackgroundInput
    previous = getMonoTime()
    nextControls = previous
    nextPreview = previous
    controlFrames = 0
  echo &"Pocket Backgrounds: {catalog.enemies.len} enemies; separate controls and preview; no audio."
  while not app.quitting:
    pollEvents()
    if app.controls.window.closeRequested: break
    if app.previewOpen and app.preview.window.closeRequested:
      app.preview.close()
      app.previewOpen = false
      if trace: echo "preview=closed"
    let
      now = getMonoTime()
      pads = pollGamepads()
      controlsFocused = app.controls.window.focused and not app.controls.window.minimized
      previewFocused = app.previewOpen and app.preview.window.focused and not app.preview.window.minimized
      mouse = controlsPoint(vec2(app.controls.window.mousePos.x.float32,
        app.controls.window.mousePos.y.float32), app.controls.window.size.x.int,
        app.controls.window.size.y.int)
    app.browser.advance((now - previous).inNanoseconds)
    previous = now
    if controlsFocused or previewFocused:
      let window = if controlsFocused: app.controls.window else: app.preview.window
      var keys: set[Button]
      for key in Button:
        if window.buttonDown[key] or window.buttonPressed[key]: keys.incl(key)
      for action in input.update(background_browser.keyboardActions(keys) +
          background_browser.gamepadActions(pads), now.ticks div 1_000_000):
        app.perform(action)
      if controlsFocused:
        if app.controls.window.scrollDelta.y != 0:
          app.perform(if app.controls.window.scrollDelta.y > 0: EnemyDown else: EnemyUp)
        if app.controls.window.buttonPressed[MouseLeft]:
          let target = mouseTarget(mouse, app.browser)
          if target.enemyIndex >= 0:
            let old = app.browser.selection.index
            app.browser.selectEnemy(target.enemyIndex)
            if old != app.browser.selection.index: app.loadSelection()
            if trace: echo &"mouseEnemy={app.browser.currentEnemy.id}"
          for action in target.actions: app.perform(action)
    else: input.reset()
    if app.previewOpen and not app.preview.window.minimized and now >= nextPreview:
      if app.renderedFrame != app.browser.frame:
        renderInto(app.decoded, app.browser.frame.int, app.output, app.workspace)
        app.renderedFrame = app.browser.frame
      app.preview.blit(app.output, cover = true)
      nextPreview = getMonoTime() + initDuration(nanoseconds = PreviewFrameNs)
    if not app.controls.window.minimized and now >= nextControls:
      let fidelity = if app.browser.hasBackground and
          SpecialUploadGroup in app.browser.currentVariant.groupIds:
        "Special encounter / preset preview only"
      else: FidelityLabel
      app.controls.blit(view.render(app.browser, mouse, app.previewOpen, fidelity))
      inc controlFrames
      nextControls = getMonoTime() + initDuration(nanoseconds = ControlsFrameNs)
      if frameLimit > 0 and controlFrames >= frameLimit: break
    sleep(2)

when isMainModule: main()
