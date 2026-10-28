import
  std/[unittest],
  paddy, pixie, windy,
  decompbound/[background_browser, background_view, battle_bg_catalog],
  ../src/tools/glblit

proc fixture(): BackgroundBrowser =
  ## Create synthetic enemy rows including an unmapped enemy and two variants.
  var catalog = BackgroundCatalog()
  for id in 1 .. 20:
    catalog.enemies.add EnemyBackgroundEntry(id: id, name: "Synthetic " & $id)
  catalog.enemies[1].variants = @[
    BackgroundVariant(groupIds: @[3], layerA: 1),
    BackgroundVariant(groupIds: @[4], layerA: 2)]
  catalog.enemies[19].variants = @[BackgroundVariant(groupIds: @[5], layerA: 1)]
  newBackgroundBrowser(catalog)

proc pad(buttons: set[GamepadButton], stickY = 0'f32): Gamepad =
  ## Produce synthetic public Paddy state without a physical device.
  for button in buttons: result.buttons = result.buttons or (1'u64 shl button.ord)
  result.axes[GamepadLStickY.ord] = stickY

suite "Background browser controls":
  test "enemy selection, variants and pause state survive navigation correctly":
    let browser = fixture()
    check browser.currentEnemy.id == 2
    browser.advance(1_000_000_000)
    check browser.frame == 60
    browser.perform(ToggleAnimation)
    browser.perform(VariantPrevious)
    check browser.variantIndex == 1 and browser.frame == 0 and browser.paused
    browser.perform(VariantNext)
    check browser.variantIndex == 0
    browser.perform(EnemyLast)
    check browser.currentEnemy.id == 20 and browser.variantIndex == 0
    browser.perform(EnemyPageUp)
    check browser.currentEnemy.id == 12
    browser.perform(EnemyFirst)
    browser.perform(EnemyUp)
    check browser.currentEnemy.id == 1 and not browser.hasBackground
    browser.advance(1_000_000_000)
    browser.perform(StepAnimation)
    check browser.frame == 0
    expect ValueError: discard browser.currentVariant

  test "rational clock, speed, reset, restart and single-step use actual elapsed time":
    let browser = fixture()
    for i in 0 ..< 1000: browser.advance(1_000_000)
    check browser.frame == 60
    browser.perform(ToggleAnimation)
    browser.advance(5_000_000_000)
    check browser.frame == 60
    browser.perform(StepAnimation)
    check browser.frame == 61
    browser.perform(ResetAnimation)
    check browser.frame == 0 and browser.paused
    browser.perform(RestartAnimation)
    check not browser.paused
    browser.perform(Slower)
    browser.perform(Slower)
    browser.perform(Slower)
    check browser.speedIndex == 0
    browser.advance(1_000_000_000)
    check browser.frame == 15
    browser.perform(Faster)
    browser.advance(1_000_000_000)
    check browser.frame == 45
    browser.perform(Faster)
    browser.perform(Faster)
    browser.perform(Faster)
    browser.advance(1_000_000_000)
    check browser.frame == 165 and browser.speedIndex == 3
    expect ValueError: browser.advance(-1)

  test "keyboard and controller use matching navigation and transport commands":
    check keyboardActions({KeyEnter, KeySpace, KeyR, KeyPeriod}) ==
      gamepadActions([pad({GamepadA, GamepadStart, GamepadB, GamepadX})])
    check keyboardActions({KeyLeft, KeyRight, KeyPageUp, KeyPageDown}) ==
      gamepadActions([pad({GamepadL1, GamepadR1, GamepadL2, GamepadR2})])
    check gamepadActions([pad({GamepadSelect, GamepadStart})]) == {QuitBrowser}
    check gamepadActions([pad({}, 0.2)]) == {}
    check gamepadActions([pad({}, -0.8)]) == {EnemyUp}
    var input: BackgroundInput
    check input.update({EnemyDown, ToggleAnimation}, 0) == @[EnemyDown, ToggleAnimation]
    check input.update({EnemyDown, ToggleAnimation}, 349).len == 0
    check input.update({EnemyDown, ToggleAnimation}, 350) == @[EnemyDown]
    check input.update({EnemyDown, ToggleAnimation}, 435) == @[EnemyDown]
    check input.update({EnemyUp, EnemyDown}, 436).len == 0
    input.reset()
    check input.update({ToggleAnimation}, 437) == @[ToggleAnimation]

  test "preview uses integer cover including centered crop at wide and small sizes":
    check integerCover(768, 672, 256, 224) == BlitViewport(x: 0, y: 0, width: 768, height: 672)
    check integerCover(1920, 1080, 256, 224) == BlitViewport(x: -64, y: -356, width: 2048, height: 1792)
    check integerCover(100, 100, 256, 224) == BlitViewport(x: -78, y: -62, width: 256, height: 224)
    check integerCover(0, 0, 256, 224).width == 0
    expect ValueError: discard integerCover(1, 1, 0, 224)

  test "mouse coordinates follow resized controls and the view reuses its canvas":
    let browser = fixture()
    check mouseTarget(vec2(100, 150), browser).enemyIndex == 0
    check mouseTarget(vec2(500, 330), browser).actions == {ToggleAnimation}
    check mouseTarget(controlsPoint(vec2(250, 165), 400, 300), browser).actions == {ToggleAnimation}
    check mouseTarget(controlsPoint(vec2(10, 330), 1000, 600), browser).actions == {}
    let view = newBackgroundControlsView()
    let image = view.render(browser, vec2(-1, -1), true, "Synthetic preview")
    check image.width == 800 and image.height == 600
    check image[50, 155] != image[50, 194]
    check view.render(browser, vec2(-1, -1), false, "Synthetic preview") == image
