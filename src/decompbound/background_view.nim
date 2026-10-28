import
  std/[strformat, strutils],
  pixie,
  ./[background_browser, companion_style, jukebox_controls]

const
  ControlsWidth* = 800
  ControlsHeight* = 600
  ListX = 48'f32
  ListY = 142'f32
  ListWidth = 318'f32
  RowHeight = 39'f32
  ButtonAreas = [
    (EnemyPageUp, rect(48, 472, 148, 34)),
    (EnemyPageDown, rect(210, 472, 156, 34)),
    (VariantPrevious, rect(426, 250, 146, 34)),
    (VariantNext, rect(586, 250, 146, 34)),
    (ToggleAnimation, rect(426, 310, 136, 48)),
    (RestartAnimation, rect(576, 310, 156, 48)),
    (StepAnimation, rect(426, 370, 136, 34)),
    (ResetAnimation, rect(576, 370, 156, 34)),
    (Slower, rect(426, 420, 48, 34)),
    (Faster, rect(684, 420, 48, 34)),
    (ToggleFullscreen, rect(426, 470, 146, 34)),
    (ShowPreview, rect(586, 470, 146, 34))
  ]

type
  BackgroundControlsView* = ref object
    image*: Image
    context: Context
    font: Font
  BackgroundMouseTarget* = object
    enemyIndex*: int
    actions*: set[BackgroundAction]

proc contains(area: Rect, point: Vec2): bool =
  ## Test nonoverlapping half-open button bounds.
  point.x >= area.x and point.x < area.x + area.w and
    point.y >= area.y and point.y < area.y + area.h

proc controlsPoint*(point: Vec2, width, height: int): Vec2 =
  ## Map mouse coordinates back through the controls window's fitted viewport.
  if width <= 0 or height <= 0: return vec2(-1, -1)
  let
    ratio = min(width.float32 / ControlsWidth.float32, height.float32 / ControlsHeight.float32)
    scale = if ratio >= 1: ratio.int.float32 else: ratio
    fittedW = max(1, int(ControlsWidth.float32 * scale))
    fittedH = max(1, int(ControlsHeight.float32 * scale))
  (point - vec2(((width - fittedW) div 2).float32, ((height - fittedH) div 2).float32)) /
    vec2(fittedW.float32 / ControlsWidth.float32, fittedH.float32 / ControlsHeight.float32)

proc mouseTarget*(point: Vec2, browser: BackgroundBrowser): BackgroundMouseTarget =
  ## Resolve controls and visible enemy rows without affecting the preview window.
  result.enemyIndex = -1
  for (action, area) in ButtonAreas:
    if area.contains(point): result.actions.incl(action)
  if rect(ListX, ListY, ListWidth, RowHeight * VisibleTracks.float32).contains(point):
    let index = browser.selection.firstVisible + int((point.y - ListY) / RowHeight)
    if index < browser.selection.count: result.enemyIndex = index

proc newBackgroundControlsView*(): BackgroundControlsView =
  ## Create a reusable control canvas with the jukebox's embedded font and palette.
  let image = newImage(ControlsWidth, ControlsHeight)
  BackgroundControlsView(image: image, context: newContext(image), font: newFont(parseTtf(FontData)))

proc box(view: BackgroundControlsView, area: Rect, color: string, radius = 12'f32) =
  ## Draw a rounded panel in the shared companion-app style.
  view.context.fillStyle = parseHtmlColor(color)
  view.context.fillRoundedRect(area, radius)

proc label(view: BackgroundControlsView, text: string, x, y, size: float32,
           color = Ink, width = 0'f32, centered = false) =
  ## Draw an embedded-font label in the control canvas.
  view.font.size = size
  view.font.paint.color = parseHtmlColor(color)
  view.image.fillText(view.font, text, translate(vec2(x, y)), bounds = vec2(width, 0),
    hAlign = (if centered: CenterAlign else: LeftAlign))

proc shortened(text: string, length: int): string =
  ## Keep ROM-decoded ASCII enemy labels inside their fixed-width panels.
  if text.len <= length: text else: text[0 ..< length - 3] & "..."

proc render*(view: BackgroundControlsView, browser: BackgroundBrowser,
             hover: Vec2, previewOpen: bool, fidelity: string): Image =
  ## Draw controls and metadata while leaving the separate preview entirely visual.
  view.image.fill(parseHtmlColor(Background))
  view.box(rect(20, 20, 760, 560), Frame, 28)
  view.label("pocket backgrounds", 40, 39, 30)
  view.label("a little atmosphere for every encounter", 42, 79, 13, Muted)
  view.box(rect(32, 108, 350, 442), Cream, 20)
  view.box(rect(35, 111, 344, 436), Panel, 17)
  view.box(rect(398, 108, 366, 442), Cream, 20)
  view.box(rect(401, 111, 360, 436), Panel, 17)
  view.label("ENEMIES", 48, 118, 12, Muted)
  view.label(&"{browser.selection.index + 1:03d} / {browser.selection.count:03d}",
    276, 118, 12, Muted)
  for row in 0 ..< VisibleTracks:
    let index = browser.selection.firstVisible + row
    if index >= browser.catalog.enemies.len: break
    let
      enemy = browser.catalog.enemies[index]
      area = rect(ListX, ListY + row.float32 * RowHeight, ListWidth, RowHeight - 3)
      selected = index == browser.selection.index
    if selected:
      view.box(area, ButtonBlue, 9)
      view.box(rect(area.x, area.y + 8, 4, 20), Gold, 2)
    elif area.contains(hover): view.box(area, RowHover, 9)
    view.label(&"{enemy.id:03d}", area.x + 12, area.y + 7, 15, Muted)
    view.label(shortened(enemy.name, 28), area.x + 57, area.y + 7, 15,
      if enemy.variants.len > 0: Ink else: Idle)
  let enemy = browser.currentEnemy
  view.label(&"ENEMY {enemy.id:03d}", 426, 127, 12, Muted)
  view.label(shortened(enemy.name, 27), 426, 151, 22, Gold)
  if browser.hasBackground:
    let variant = browser.currentVariant
    view.label(&"Background {browser.variantIndex + 1} / {enemy.variants.len}", 426, 187, 19)
    var groups: seq[string]
    for i in 0 ..< min(variant.groupIds.len, 5): groups.add($variant.groupIds[i])
    let extra = if variant.groupIds.len > 5: " ..." else: ""
    view.label("Encounters: " & groups.join(", ") & extra, 426, 219, 12, Muted)
    view.label(&"Layers {variant.layerA} + {variant.layerB}   Framing {variant.letterbox}",
      426, 290, 11, Muted)
  else:
    view.label("No mapped encounter", 426, 188, 19)
    view.label("No background is assigned by the catalog.", 426, 220, 12, Muted)
  for (action, area) in ButtonAreas:
    let
      hovered = area.contains(hover)
      primary = action == ToggleAnimation
      foreground = if hovered or primary: DarkInk else: Ink
      background = if hovered: Mint elif primary: Pink else: ButtonBlue
      text = case action
        of EnemyPageUp: "page up"
        of EnemyPageDown: "page down"
        of VariantPrevious: "< background"
        of VariantNext: "background >"
        of ToggleAnimation: (if browser.paused: "play" else: "pause")
        of RestartAnimation: "restart"
        of StepAnimation: "step frame"
        of ResetAnimation: "reset"
        of Slower: "-"
        of Faster: "+"
        of ToggleFullscreen: "fullscreen"
        of ShowPreview: (if previewOpen: "show preview" else: "reopen preview")
        else: ""
    view.box(area, background)
    view.label(text, area.x, area.y + (if area.h > 40: 12'f32 else: 7'f32),
      if primary: 20'f32 else: 14'f32, foreground, area.w, true)
  view.label("SPEED  " & SpeedLabels[browser.speedIndex], 484, 427, 14, Gold, 186, true)
  view.label(&"Frame {browser.frame}  /  " & (if browser.paused: "paused" else: "playing"),
    426, 516, 11, Muted)
  view.label(shortened(fidelity, 48), 48, 520, 11, Gold)
  view.label("Up/Down: enemy  Left/Right: background  Space: pause  Enter: restart  F11: fullscreen",
    36, 558, 11, Muted)
  view.label("Pad: Up/Down enemy  L/R background  Start pause  A restart  Y fullscreen     P: reopen preview",
    36, 577, 10, Muted)
  view.image
