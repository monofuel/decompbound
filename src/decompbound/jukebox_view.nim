import
  std/[math, strformat],
  pixie,
  ./jukebox_controls

const
  ViewWidth* = 800
  ViewHeight* = 600
  ListX = 438'f32
  ListY = 147'f32
  RowHeight = 41'f32
  ListWidth = 310'f32
  FontData = staticRead("../../data/silky/IBMPlexSans-Regular.ttf")
  Cream = "#FFF9EF"
  Ink = "#403952"
  Muted = "#776E89"
  Lavender = "#DFD3F2"
  Pink = "#F6B4C5"
  Mint = "#B9DCCB"

type
  JukeboxView* = ref object
    image*: Image
    context: Context
    font: Font
  JukeboxDisplay* = object
    selection*: TrackSelection
    tracks*: seq[int]
    songId*: int
    playing*, paused*: bool
    elapsedSeconds*: int
    volume*: int
    level*: float32
    hover*: Vec2
    controllerCount*: int
  MouseTarget* = object
    trackIndex*: int = -1
    actions*: set[JukeboxAction]

const
  ControlRects = [
    (PreviousTrack, rect(50, 399, 66, 48)),
    (TogglePlayback, rect(126, 391, 158, 64)),
    (NextTrack, rect(294, 399, 66, 48)),
    (StopPlayback, rect(159, 466, 92, 30)),
    (Quieter, rect(50, 511, 36, 32)),
    (Louder, rect(324, 511, 36, 32)),
    (PageUp, rect(438, 491, 148, 36)),
    (PageDown, rect(600, 491, 148, 36))
  ]

proc containsPoint(area: Rect, point: Vec2): bool =
  ## Test half-open bounds so adjacent controls never share a click.
  point.x >= area.x and point.x < area.x + area.w and
    point.y >= area.y and point.y < area.y + area.h

proc mouseTarget*(point: Vec2, selection: TrackSelection): MouseTarget =
  ## Resolve list rows and playback controls in the same coordinates as drawing.
  result.trackIndex = -1
  for (action, area) in ControlRects:
    if area.containsPoint(point): result.actions.incl(action)
  if rect(ListX, ListY, ListWidth, RowHeight * VisibleTracks.float32).containsPoint(point):
    let index = selection.firstVisible + int((point.y - ListY) / RowHeight)
    if index < selection.count: result.trackIndex = index

proc viewPoint*(point: Vec2, width, height: int): Vec2 =
  ## Undo the centered viewport and its integer-above-native scaling policy.
  if width <= 0 or height <= 0: return vec2(-1, -1)
  let
    scale = min(width.float32 / ViewWidth.float32, height.float32 / ViewHeight.float32)
    fitted = if scale >= 1: floor(scale) else: scale
    fittedWidth = max(1, int(ViewWidth.float32 * fitted))
    fittedHeight = max(1, int(ViewHeight.float32 * fitted))
    origin = vec2(((width - fittedWidth) div 2).float32,
      ((height - fittedHeight) div 2).float32)
  (point - origin) / vec2(fittedWidth.float32 / ViewWidth.float32,
    fittedHeight.float32 / ViewHeight.float32)

proc newJukeboxView*(): JukeboxView =
  ## Create a reusable canvas and embed the existing freely licensed UI font.
  let image = newImage(ViewWidth, ViewHeight)
  JukeboxView(image: image, context: newContext(image), font: newFont(parseTtf(FontData)))

proc box(view: JukeboxView, area: Rect, color: string, radius = 12'f32) =
  ## Fill a rounded panel using only our own procedural artwork.
  view.context.fillStyle = parseHtmlColor(color)
  view.context.fillRoundedRect(area, radius)

proc label(view: JukeboxView, text: string, x, y, size: float32,
           color = Ink, width = 0'f32, centered = false) =
  ## Draw text with the embedded font, optionally centered within a fixed width.
  view.font.size = size
  view.font.paint.color = parseHtmlColor(color)
  view.image.fillText(view.font, text, translate(vec2(x, y)),
    bounds = vec2(width, 0), hAlign = (if centered: CenterAlign else: LeftAlign))

proc circle(view: JukeboxView, x, y, radius: float32, color: string) =
  ## Draw a filled circle for cassette reels and small indicators.
  view.context.fillStyle = parseHtmlColor(color)
  view.context.fillCircle(Circle(pos: vec2(x, y), radius: radius))

proc triangle(view: JukeboxView, x, y: float32, color: string) =
  ## Draw the familiar right-facing playback symbol without a font glyph.
  let context = view.context
  context.fillStyle = parseHtmlColor(color)
  context.beginPath()
  context.moveTo(x, y)
  context.lineTo(x + 15, y + 10)
  context.lineTo(x, y + 20)
  context.closePath()
  context.fill()

proc cassette(view: JukeboxView, display: JukeboxDisplay) =
  ## Draw a smiling cassette whose reels turn with generated playback time.
  view.box(rect(50, 157, 310, 185), "#C6B9DD", 23)
  view.box(rect(50, 151, 310, 185), Lavender, 23)
  view.box(rect(68, 168, 274, 91), Cream, 12)
  view.label("SIDE A  /  EARTHBOUND", 88, 181, 13, Muted)
  view.label(if display.songId > 0: &"TRACK {display.songId:03d}" else: "YOUR LITTLE MIXTAPE",
    88, 204, 23)
  view.box(rect(84, 245, 242, 61), "#9082AD", 24)
  for x in [130'f32, 280'f32]:
    view.circle(x, 275, 25, Cream)
    view.circle(x, 275, 16, Lavender)
    view.circle(x, 275, 6, Ink)
    let phase = display.elapsedSeconds.float32 * 0.7
    for tooth in 0 ..< 3:
      let angle = phase + tooth.float32 * (2 * PI.float32 / 3)
      view.circle(x + cos(angle) * 20, 275 + sin(angle) * 20, 3, Muted)
  view.circle(194, 270, 2, Cream)
  view.circle(216, 270, 2, Cream)
  view.context.strokeStyle = parseHtmlColor(Cream)
  view.context.lineWidth = 2
  view.context.beginPath()
  view.context.moveTo(198, 280)
  view.context.bezierCurveTo(201, 285, 209, 285, 212, 280)
  view.context.stroke()
  for x in [65'f32, 345'f32]:
    for y in [167'f32, 319'f32]:
      view.circle(x, y, 3, Muted)

proc render*(view: JukeboxView, display: JukeboxDisplay): Image =
  ## Render the complete music-only player; no game graphics are extracted.
  view.image.fill(parseHtmlColor(Cream))
  view.box(rect(20, 20, 760, 560), "#F1EAF7", 28)
  view.box(rect(32, 32, 376, 523), "#FFFDF8", 23)
  view.box(rect(420, 99, 344, 456), "#FFFDF8", 20)
  view.circle(365, 65, 13, Pink)
  view.circle(371, 61, 4, Cream)
  view.label("pocket jukebox", 50, 48, 31)
  view.label("a little place for big adventures", 50, 92, 14, Muted)
  view.label("EARTHBOUND", 438, 46, 19)
  view.label(&"{display.tracks.len} tracks / pick a number", 438, 75, 13, Muted)
  view.cassette(display)
  let
    status = if display.paused: "PAUSED" elif display.playing: "NOW PLAYING" else: "READY WHEN YOU ARE"
    elapsed = &"{display.elapsedSeconds div 60:02d}:{display.elapsedSeconds mod 60:02d}"
  view.circle(59, 367, 4, if display.playing: "#629E86" else: "#B4A6C6")
  view.label(status, 72, 356, 12, Muted)
  view.label(elapsed, 306, 351, 20)
  for i in 0 ..< 12:
    let lit = display.playing and i.float32 / 12 < display.level
    view.box(rect(221 + i.float32 * 6, 360, 3, 12),
      if lit: "#629E86" else: "#E8E1EF", 1)
  for (action, area) in ControlRects:
    let hover = area.containsPoint(display.hover)
    let base = if action == TogglePlayback: Pink else: Lavender
    view.box(area, if hover: Mint else: base, 12)
    case action
    of PreviousTrack: view.label("|<<", area.x, area.y + 10, 20, width = area.w, centered = true)
    of NextTrack: view.label(">>|", area.x, area.y + 10, 20, width = area.w, centered = true)
    of TogglePlayback:
      if display.playing:
        view.box(rect(area.x + 27, area.y + 22, 5, 20), Ink, 1)
        view.box(rect(area.x + 37, area.y + 22, 5, 20), Ink, 1)
      else: view.triangle(area.x + 27, area.y + 22, Ink)
      view.label(if display.playing: "pause" else: "play", area.x + 54, area.y + 17, 22)
    of StopPlayback: view.label("stop", area.x, area.y + 4, 15, width = area.w, centered = true)
    of Quieter: view.label("-", area.x, area.y + 1, 23, width = area.w, centered = true)
    of Louder: view.label("+", area.x, area.y + 1, 23, width = area.w, centered = true)
    of PageUp: view.label("page up", area.x, area.y + 7, 15, width = area.w, centered = true)
    of PageDown: view.label("page down", area.x, area.y + 7, 15, width = area.w, centered = true)
    else: discard
  view.label(&"VOLUME   {display.volume}%", 102, 499, 11, Muted)
  view.box(rect(102, 524, 205, 6), Lavender, 3)
  if display.volume > 0:
    view.box(rect(102, 524, 205 * display.volume.float32 / 100, 6), "#8EBDA8", 3)
  view.label("TRACK LIST", 438, 116, 12, Muted)
  view.label(&"{display.selection.index + 1:03d} / {display.tracks.len:03d}", 660, 115, 12, Muted)
  for row in 0 ..< VisibleTracks:
    let index = display.selection.firstVisible + row
    if index >= display.tracks.len: break
    let
      y = ListY + row.float32 * RowHeight
      selected = index == display.selection.index
      songId = display.tracks[index]
      area = rect(ListX, y, ListWidth, RowHeight - 4)
    if selected:
      view.box(area, Lavender, 9)
      view.box(rect(ListX, y + 8, 4, 21), "#8A6BA7", 2)
    elif area.containsPoint(display.hover):
      view.box(area, "#F4EFF8", 9)
    view.label(&"{songId:03d}", ListX + 16, y + 6, 17, Muted)
    view.label(&"Track {songId:03d}", ListX + 74, y + 6, 17)
    if songId == display.songId:
      if display.playing: view.triangle(ListX + 274, y + 8, "#629E86")
      elif display.paused: view.label("||", ListX + 274, y + 5, 17, Muted)
  view.label("Arrows: browse / skip   Enter: play   Space: pause   S: stop   +/-: volume",
    38, 559, 11, Muted)
  view.label(if display.controllerCount > 0:
    "Pad: up/down browse   bottom play   right stop   Start pause   L/R skip   left/right volume"
    else: "Mouse: click a track or control / wheel to browse       Paddy: connect a controller anytime",
    38, 576, 10, Muted)
  view.image
