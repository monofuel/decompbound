import
  std/[unittest],
  paddy, pixie, windy,
  decompbound/[bestiary, bestiary_browser, bestiary_scene, bestiary_view,
    battle_bg_catalog, music_player],
  ./bestiary/fixtures

proc fixture(): BestiaryBrowser =
  ## Build a synthetic public catalog with duplicate names and shared and absent music.
  let library = BestiaryLibrary(catalog: BackgroundCatalog(rom: authoredRom()),
    music: MusicLibrary(trackIds: @[1, 2]))
  for id in 1..20:
    let song = if id == 3: 2 elif id == 4: 0 else: 1
    let name = if id in [1, 2]: "Twin Fixture" else: "Fixture " & $id
    library.enemies.add EnemyRecord(id: id, name: name, musicId: song)
    library.catalog.enemies.add EnemyBackgroundEntry(id: id, name: name)
  library.catalog.enemies[0].variants = @[
    BackgroundVariant(groupIds: @[1], layerA: 1),
    BackgroundVariant(groupIds: @[2], layerA: 2)]
  newBestiaryBrowser(library)

proc pad(buttons: set[GamepadButton], stickY = 0'f32): Gamepad =
  ## Create synthetic public controller state without opening a device.
  for button in buttons: result.buttons = result.buttons or (1'u64 shl button.ord)
  result.axes[GamepadLStickY.ord] = stickY

suite "Bestiary browser and shared transport":
  test "automatic themes preserve same-song progress and coalesce rapid changes":
    let browser = fixture()
    check browser.updateTheme(0) == @[ThemeCommand(kind: StartTheme, songId: 1)]
    browser.selectEnemy(1, 100)
    check browser.currentEnemy.id == 2
    check browser.updateTheme(100).len == 0
    check browser.activeSong == 1
    browser.selectEnemy(2, 110)
    check browser.updateTheme(110) == @[ThemeCommand(kind: StopTheme)]
    browser.selectEnemy(3, 120)
    check browser.updateTheme(300).len == 0
    check browser.activeSong == 0
    browser.selectEnemy(2, 400)
    check browser.updateTheme(549).len == 0
    check browser.updateTheme(550) == @[ThemeCommand(kind: StartTheme, songId: 2)]

  test "pause, reset and restart couple music commands and visual clock":
    let browser = fixture()
    discard browser.updateTheme(0)
    for tick in 0 ..< 1000: browser.advance(1_000_000)
    check browser.frame == 60
    browser.perform(PauseBoth)
    browser.advance(1_000_000_000)
    check browser.paused and browser.frame == 60
    browser.perform(ResetBoth, 100)
    check browser.paused and browser.frame == 0
    check browser.updateTheme(100) == @[
      ThemeCommand(kind: StopTheme), ThemeCommand(kind: StartTheme, songId: 1)]
    browser.perform(RestartBoth, 200)
    check not browser.paused and browser.frame == 0
    check browser.updateTheme(200).len == 2
    expect ValueError: browser.advance(-1)

  test "background changes reset only visuals and preserve pause and song":
    let browser = fixture()
    discard browser.updateTheme(0)
    browser.advance(1_000_000_000)
    browser.perform(PauseBoth)
    browser.perform(PreviousBackground)
    check browser.variantIndex == 1 and browser.frame == 0 and browser.paused
    check browser.updateTheme(500).len == 0
    browser.perform(NextBackground)
    check browser.variantIndex == 0
    browser.perform(EnemyLast)
    check browser.currentEnemy.id == 20
    browser.perform(EnemyPageUp)
    check browser.currentEnemy.id == 12
    browser.perform(EnemyFirst)
    browser.perform(EnemyUp)
    check browser.currentEnemy.id == 1

  test "search retains duplicate identities and handles empty results and numeric ids":
    let browser = fixture()
    discard browser.updateTheme(0)
    browser.selectEnemy(1)
    browser.setQuery("tWiN")
    check browser.visible.len == 2 and browser.currentEnemy.id == 2
    browser.setQuery("no such fixture")
    check not browser.hasSelection
    check browser.updateTheme(0) == @[ThemeCommand(kind: StopTheme)]
    expect ValueError: discard browser.currentEnemy
    browser.perform(EnemyDown)
    browser.setQuery("")
    check browser.currentEnemy.id == 2
    browser.setQuery("#20")
    check browser.visible.len == 1 and browser.currentEnemy.id == 20
    browser.setQuery("3")
    check browser.currentEnemy.id == 3

  test "text focus protects shortcuts and keyboard and Paddy share transport":
    check keyboardActions({KeyM, KeyR, KeySpace}, true) == {}
    check keyboardActions({KeyEscape}, true) == {LeaveSearch}
    check keyboardActions({KeyEnter}, true) == {LeaveSearch}
    check keyboardActions({KeyLeftControl, KeyF}) == {FocusSearch}
    check keyboardActions({KeyEnter, KeySpace, KeyR, KeyM, KeyF11}) ==
      gamepadActions([pad({GamepadA, GamepadStart, GamepadB, GamepadX, GamepadY})])
    check gamepadActions([pad({GamepadSelect, GamepadStart})]) == {QuitBestiary}
    check gamepadActions([pad({}, 0.2)]) == {}
    check gamepadActions([pad({}, -0.8)]) == {EnemyUp}
    var input: BestiaryInput
    check input.update({EnemyDown, PauseBoth}, 0) == @[EnemyDown, PauseBoth]
    check input.update({EnemyDown, PauseBoth}, 349).len == 0
    check input.update({EnemyDown, PauseBoth}, 350) == @[EnemyDown]
    check input.update({EnemyUp, EnemyDown}, 351).len == 0
    input.reset()
    check input.update({PauseBoth}, 352) == @[PauseBoth]

  test "native portrait composition preserves transparent pixels and stage clearing":
    let image = newImage(8, 8)
    let portrait = newImage(2, 2)
    image.fill(rgba(0, 255, 0, 255))
    portrait.fill(rgba(255, 0, 0, 255))
    portrait[0, 0] = rgba(0, 0, 0, 0)
    image.composePortrait(portrait)
    check image[3, 3] == rgba(0, 255, 0, 255)
    check image[4, 3] == rgba(255, 0, 0, 255)
    check image[0, 0] == rgba(0, 255, 0, 255)
    let browser = newBestiaryBrowser(newBestiaryLibrary(authoredRom()))
    let scene = newBestiaryScene()
    check scene.render(browser)[128, 112].a == 255
    browser.selectEnemy(2)
    check scene.render(browser)[128, 112] == rgba(0, 0, 0, 255)
    browser.setQuery("no matches")
    check scene.render(browser)[128, 112] == rgba(0, 0, 0, 255)

  test "resized hit testing and nearest scene pixels agree with actual controls":
    let browser = fixture()
    check mouseTarget(vec2(80, 200), browser).row == 0
    check mouseTarget(vec2(80, 130), browser).search
    check mouseTarget(bestiaryPoint(vec2(42, 342), 480, 360), browser).actions == {PauseBoth}
    check mouseTarget(bestiaryPoint(vec2(10, 342), 1200, 720), browser).actions == {}
    let
      view = newBestiaryView()
      scene = newImage(256, 224)
    scene.fill(rgba(1, 2, 3, 255))
    scene[0, 0] = rgba(200, 0, 0, 255)
    let canvas = view.render(browser, scene, BestiaryDisplay(volume: 80, audioEnabled: true), vec2(-1, -1))
    check canvas.width == 960 and canvas.height == 720
    check canvas[SceneX, SceneY] == scene[0, 0]
    check canvas[SceneX + 1, SceneY + 1] == scene[0, 0]
    check canvas[SceneX + 2, SceneY] == scene[1, 0]
    browser.setQuery("absent")
    discard view.render(browser, scene, BestiaryDisplay(volume: 80), vec2(-1, -1))
