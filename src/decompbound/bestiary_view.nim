import
  std/[strformat],
  pixie,
  ./[bestiary, bestiary_browser, companion_style, jukebox_controls]

type
  BestiaryDisplay* = object
    volume*, controllers*: int
    muted*, audioEnabled*: bool
  BestiaryMouseTarget* = object
    row*: int
    search*: bool
    actions*: set[BestiaryAction]
  ViewState = object
    selected, first, variant, song, volume, controllers: int
    query, name, hp, pp, rewards, drop, theme, encounter, portrait: string
    paused, searching, muted, audioEnabled: bool
    hover: Vec2
  BestiaryView* = ref object
    image*: Image
    context: Context
    font: Font
    initialized: bool
    previous: ViewState

const
  BestiaryWidth* = 960
  BestiaryHeight* = 720
  SceneX* = 374
  SceneY* = 154
  SceneScale* = 2
  SearchArea = rect(36, 114, 254, 40)
  ListArea = rect(36, 184, 254, 288)
  RowHeight = 36'f32
  Buttons = [
    (EnemyPageUp, rect(36, 484, 120, 30)),
    (EnemyPageDown, rect(170, 484, 120, 30)),
    (PreviousBackground, rect(340, 614, 150, 30)),
    (NextBackground, rect(770, 614, 150, 30)),
    (PauseBoth, rect(24, 666, 120, 38)),
    (RestartBoth, rect(156, 666, 120, 38)),
    (ResetBoth, rect(288, 666, 100, 38)),
    (ToggleMusicMute, rect(400, 666, 118, 38)),
    (VolumeDown, rect(538, 666, 38, 38)),
    (VolumeUp, rect(678, 666, 38, 38)),
    (Fullscreen, rect(740, 666, 196, 38))]

proc contains(area: Rect, point: Vec2): bool =
  ## Test half-open hit areas without overlapping neighboring controls.
  point.x >= area.x and point.x < area.x + area.w and point.y >= area.y and point.y < area.y + area.h

proc bestiaryPoint*(point: Vec2, width, height: int): Vec2 =
  ## Invert the app's fitted viewport for resized mouse interaction.
  if width <= 0 or height <= 0: return vec2(-1, -1)
  let
    ratio = min(width.float32 / BestiaryWidth.float32, height.float32 / BestiaryHeight.float32)
    scale = if ratio >= 1: ratio.int.float32 else: ratio
    fittedW = max(1, int(BestiaryWidth.float32 * scale))
    fittedH = max(1, int(BestiaryHeight.float32 * scale))
  (point - vec2(((width - fittedW) div 2).float32, ((height - fittedH) div 2).float32)) /
    vec2(fittedW.float32 / BestiaryWidth.float32, fittedH.float32 / BestiaryHeight.float32)

proc mouseTarget*(point: Vec2, browser: BestiaryBrowser): BestiaryMouseTarget =
  ## Resolve list, search and transport hit targets in logical canvas coordinates.
  result.row = -1
  result.search = SearchArea.contains(point)
  for (action, area) in Buttons:
    if area.contains(point): result.actions.incl(action)
  if ListArea.contains(point):
    let index = browser.selection.firstVisible + int((point.y - ListArea.y) / RowHeight)
    if index < browser.selection.count: result.row = index

proc newBestiaryView*(): BestiaryView =
  ## Allocate reusable UI storage with the companion apps' embedded font and colors.
  let image = newImage(BestiaryWidth, BestiaryHeight)
  BestiaryView(image: image, context: newContext(image), font: newFont(parseTtf(FontData)))

proc box(view: BestiaryView, area: Rect, color: string, radius = 10'f32) =
  ## Draw a rounded panel or control using the shared palette.
  view.context.fillStyle = parseHtmlColor(color)
  view.context.fillRoundedRect(area, radius)

proc label(view: BestiaryView, text: string, x, y, size: float32,
           color = Ink, width = 0'f32, centered = false) =
  ## Draw a label without introducing an external font dependency.
  view.font.size = size
  view.font.paint.color = parseHtmlColor(color)
  view.image.fillText(view.font, text, translate(vec2(x, y)), bounds = vec2(width, 0),
    hAlign = (if centered: CenterAlign else: LeftAlign))

proc shortened(text: string, limit: int): string =
  ## Fit runtime-decoded ASCII labels in their fixed sidebar space.
  if text.len <= limit: text else: text[0 ..< limit - 3] & "..."

proc state(browser: BestiaryBrowser, display: BestiaryDisplay, hover: Vec2): ViewState =
  ## Gather only the values that require repainting the controls.
  result = ViewState(first: browser.selection.firstVisible, variant: browser.variantIndex,
    song: browser.activeSong, query: browser.query, paused: browser.paused,
    searching: browser.searching, volume: display.volume, muted: display.muted,
    audioEnabled: display.audioEnabled, controllers: display.controllers, hover: hover)
  if browser.hasSelection:
    let
      enemy = browser.currentEnemy
      portrait = browser.library.portrait(enemy.id)
      variants = browser.variants
    result.selected = enemy.id
    result.name = enemy.name
    result.hp = $enemy.hp
    result.pp = $enemy.pp
    result.rewards = &"EXP {enemy.exp}    ${enemy.money}"
    result.drop = if enemy.dropItemId == 0: "None" else: enemy.dropItemName
    result.drop.add(if enemy.dropItemId == 0: "" else: " (" & dropFreqLabel(enemy.dropFreq) & ")")
    result.portrait = if portrait.widthPx == 0: "No standard battle portrait" else: &"Portrait {portrait.widthPx} x {portrait.heightPx}"
    result.theme = if not display.audioEnabled: "Audio disabled by --mute"
      elif browser.playableSong == 0: "No assigned theme"
      elif browser.activeSong == 0: &"Enemy theme {enemy.musicId:03d} / loading"
      else: &"Enemy theme {enemy.musicId:03d}"
    if variants.len == 0: result.encounter = "No mapped encounter background"
    else:
      let variant = variants[browser.variantIndex]
      result.encounter = &"Background {browser.variantIndex + 1}/{variants.len} / group {variant.groupIds[0]}"
      if 478 in variant.groupIds: result.encounter = "Special encounter / preset preview"

proc drawChrome(view: BestiaryView, browser: BestiaryBrowser, state: ViewState) =
  ## Repaint static controls only when selection, input, or playback state changes.
  view.image.fill(parseHtmlColor(Background))
  view.box(rect(12, 12, 936, 696), Frame, 26)
  view.label("pocket bestiary", 28, 28, 30)
  view.label("the neighbors are a little unusual", 30, 70, 13, Muted)
  view.label(&"{state.controllers} pad(s)", 822, 63, 12, Muted)
  for area in [rect(20, 100, 286, 552), rect(320, 100, 620, 552)]:
    view.box(area, Cream, 18)
    view.box(rect(area.x + 3, area.y + 3, area.w - 6, area.h - 6), Panel, 15)
  view.box(SearchArea, if state.searching: ButtonBlue else: RowHover, 8)
  let searchText = if state.query.len > 0: shortened(state.query, 27)
    elif state.searching: "type a name or #id..." else: "search name / #id"
  view.label(searchText & (if state.searching: " |" else: ""), 46, 123, 14, if state.searching: Ink else: Muted)
  view.label(&"ENEMIES   {browser.visible.len} / {browser.library.enemies.len}", 38, 163, 11, Muted)
  for row in 0 ..< VisibleTracks:
    let index = browser.selection.firstVisible + row
    if index >= browser.visible.len: break
    let
      enemy = browser.library.enemies[browser.visible[index]]
      area = rect(ListArea.x, ListArea.y + row.float32 * RowHeight, ListArea.w, RowHeight - 2)
      selected = index == browser.selection.index
    if selected:
      view.box(area, ButtonBlue, 8)
      view.box(rect(area.x, area.y + 6, 4, 20), Gold, 2)
    elif area.contains(state.hover): view.box(area, RowHover, 8)
    view.label(&"{enemy.id:03d}", area.x + 10, area.y + 6, 14, Muted)
    view.label(shortened(enemy.name, 23), area.x + 48, area.y + 6, 14)
  if state.selected == 0:
    view.label("No enemies match", 340, 115, 24, Gold)
    view.label("Edit or clear the search to keep browsing.", 340, 142, 13, Muted)
  else:
    view.label(shortened(state.name, 35), 340, 111, 24, Gold)
    view.label(state.portrait & "   /   " & state.theme, 340, 139, 11, Muted)
    view.label(&"HP {state.hp}    PP {state.pp}", 38, 530, 17)
    view.label(state.rewards, 38, 559, 14, Gold)
    view.label("DROP", 38, 588, 10, Muted)
    view.label(shortened(state.drop, 33), 38, 605, 13)
    view.label(state.encounter, 496, 621, 11, Muted, 268, true)
  for (action, area) in Buttons:
    let
      hovered = area.contains(state.hover)
      primary = action == PauseBoth
      text = case action
        of EnemyPageUp: "page up"
        of EnemyPageDown: "page down"
        of PreviousBackground: "< background"
        of NextBackground: "background >"
        of PauseBoth: (if state.paused: "play" else: "pause")
        of RestartBoth: "restart"
        of ResetBoth: "reset"
        of ToggleMusicMute: (if not state.audioEnabled: "audio off" elif state.muted: "unmute" else: "mute music")
        of VolumeDown: "-"
        of VolumeUp: "+"
        of Fullscreen: "fullscreen"
        else: ""
    view.box(area, if hovered: Mint elif primary: Pink else: ButtonBlue, 9)
    view.label(text, area.x, area.y + 7, if primary: 18'f32 else: 14'f32,
      if hovered or primary: DarkInk else: Ink, area.w, true)
  view.label(&"{state.volume}%", 580, 675, 17, Gold, 94, true)

proc render*(view: BestiaryView, browser: BestiaryBrowser, scene: Image,
             display: BestiaryDisplay, hover: Vec2): Image =
  ## Composite a nearest-scaled native scene into cached controls without per-frame assets.
  if scene == nil or scene.width != 256 or scene.height != 224:
    raise newException(ValueError, "Bestiary scene must be 256 x 224.")
  let current = state(browser, display, hover)
  if not view.initialized or current != view.previous:
    view.drawChrome(browser, current)
    view.previous = current
    view.initialized = true
  for y in 0 ..< scene.height * SceneScale:
    let sourceRow = (y div SceneScale) * scene.width
    let destinationRow = (SceneY + y) * BestiaryWidth + SceneX
    for x in 0 ..< scene.width * SceneScale:
      view.image.data[destinationRow + x] = scene.data[sourceRow + x div SceneScale]
  view.image
