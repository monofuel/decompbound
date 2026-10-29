import
  std/[math, monotimes, os, osproc, streams, strutils, tempfiles, times],
  vmath,
  windy/platforms/linux/x11/[x, xevent, xlib]

type
  XErrorCallback = proc(d: Display, event: ptr XErrorEvent): cint {.cdecl.}
  TraceState = object
    x, y, zoom: float64
    selectedX, selectedY, region: int
    viewportWidth, viewportHeight, canvasWidth, canvasHeight: int
    stateRevision, worldRow, worldScroll: int
    enabledFlags, worldPanel: string
    selected, grid: bool

const
  WaitSeconds = 10
  InputDelayMs = 90
  WindowTitle = "Pocket Atlas"
  TestBinaryEnv = "DECOMPBOUND_MAP_TEST_BINARY"
  EscapeKey = 0xFF1B.culong
  PlusKey = 0x003D.culong
  RightKey = 0xFF53.culong
  LeftKey = 0xFF51.culong
  EnterKey = 0xFF0D.culong
  PageDownKey = 0xFF56.culong
  HomeKey = 0xFF50.culong
  FullscreenKey = 0xFFC8.culong
  GridKey = 0x0067.culong
  TabKey = 0xFF09.culong
  DownKey = 0xFF54.culong

var
  xError = false
  xErrorDetails: string

proc queryTree(d: Display, window: Window, root, parent: ptr Window,
    children: ptr ptr UncheckedArray[Window], count: ptr cuint): cint
    {.cdecl, importc: "XQueryTree", dynlib: libX11.}
proc fetchName(d: Display, window: Window, name: ptr cstring): cint
    {.cdecl, importc: "XFetchName", dynlib: libX11.}
proc keycode(d: Display, symbol: culong): uint8
    {.cdecl, importc: "XKeysymToKeycode", dynlib: libX11.}
proc sendEvent(d: Display, window: Window, propagate: cint, mask: clong,
    event: ptr XEvent): cint {.cdecl, importc: "XSendEvent", dynlib: libX11.}
proc closeDisplay(d: Display): cint {.cdecl, importc: "XCloseDisplay", dynlib: libX11.}
proc warp(d: Display, source, destination: Window, sx, sy: cint,
    sw, sh: cuint, dx, dy: cint): cint {.cdecl, importc: "XWarpPointer", dynlib: libX11.}
proc setErrorHandler(callback: XErrorCallback): pointer
    {.cdecl, importc: "XSetErrorHandler", dynlib: libX11.}
proc sync(d: Display, discardEvents: cint): cint
    {.cdecl, importc: "XSync", dynlib: libX11.}

proc recordXError(d: Display, event: ptr XErrorEvent): cint {.cdecl.} =
  ## Retain protocol failures so assertions can unwind child processes cleanly.
  xError = true
  xErrorDetails.add(" code=" & $event.error_code.ord & " request=" &
    $event.request_code.ord & " resource=" & $event.resourceid)
  0

proc namedChild(d: Display, parent: Window, depth = 0): Window =
  ## Find the app beneath window-manager frames on our private X server.
  if depth > 8: return 0
  var
    root, ancestor: Window
    children: ptr UncheckedArray[Window]
    count: cuint
  doAssert queryTree(d, parent, addr root, addr ancestor, addr children, addr count) != 0
  defer:
    if children != nil: XFree(children)
  for index in 0 ..< count.int:
    var name: cstring
    if fetchName(d, children[index], addr name) != 0 and name != nil:
      let matches = $name == WindowTitle
      XFree(name)
      if matches: return children[index]
    let nested = namedChild(d, children[index], depth + 1)
    if nested != 0: return nested

proc findWindow(d: Display): Window =
  ## Wait for the real application window instead of guessing a startup delay.
  let deadline = getMonoTime() + initDuration(seconds = WaitSeconds)
  while getMonoTime() < deadline:
    result = namedChild(d, d.defaultRootWindow)
    if result != 0: return
    sleep(10)
  raise newException(IOError, "Pocket Atlas did not open its window.")

proc waitTrace(path, expected: string, occurrence = 1) =
  ## Wait for the requested application action to be reported after event handling.
  let deadline = getMonoTime() + initDuration(seconds = WaitSeconds)
  while getMonoTime() < deadline:
    if fileExists(path) and readFile(path).count(expected) >= occurrence: return
    sleep(10)
  raise newException(AssertionDefect, "Missing trace: " & expected & "\n" & readFile(path))

proc state(path: string): TraceState =
  ## Read the last full action state emitted by the actual application.
  for line in readFile(path).splitLines:
    if not line.startsWith("action="): continue
    for item in line.splitWhitespace:
      if item.startsWith("center="):
        let point = item[7 .. ^1].split(',')
        result.x = parseFloat(point[0])
        result.y = parseFloat(point[1])
      elif item.startsWith("zoom="): result.zoom = parseFloat(item[5 .. ^1])
      elif item.startsWith("region="): result.region = parseInt(item[7 .. ^1])
      elif item.startsWith("grid="): result.grid = parseBool(item[5 .. ^1])
      elif item.startsWith("enabledFlags="): result.enabledFlags = item[13 .. ^1]
      elif item.startsWith("stateRevision="): result.stateRevision = parseInt(item[14 .. ^1])
      elif item.startsWith("worldpanel="): result.worldPanel = item[11 .. ^1]
      elif item.startsWith("row="): result.worldRow = parseInt(item[4 .. ^1])
      elif item.startsWith("scroll="): result.worldScroll = parseInt(item[7 .. ^1])
      elif item.startsWith("viewport="):
        let size = item[9 .. ^1].split('x')
        result.viewportWidth = parseInt(size[0])
        result.viewportHeight = parseInt(size[1])
      elif item.startsWith("canvas="):
        let size = item[7 .. ^1].split('x')
        result.canvasWidth = parseInt(size[0])
        result.canvasHeight = parseInt(size[1])
      elif item.startsWith("selected="):
        let
          values = item[9 .. ^1].split(':')
          point = values[1].split(',')
        result.selected = parseBool(values[0])
        result.selectedX = parseInt(point[0])
        result.selectedY = parseInt(point[1])

proc key(d: Display, window: Window, symbol: culong, down: bool) =
  ## Send one keyboard edge through Windy's real X11 event handling.
  var event = XEvent(key: XKeyEvent(kind: if down: xeKeyPress else: xeKeyRelease,
    display: d, window: window, root: d.defaultRootWindow,
    keycode: keycode(d, symbol).cuint, same_screen: 1))
  doAssert sendEvent(d, window, 0, if down: 1 else: 2, addr event) != 0
  d.XFlush()

proc tap(d: Display, window: Window, symbol: culong) =
  ## Keep press and release on distinct application polls.
  key(d, window, symbol, true)
  sleep(InputDelayMs)
  key(d, window, symbol, false)
  sleep(InputDelayMs)

proc pointer(d: Display, window: Window, x, y: int) =
  ## Move the private X server's pointer without touching the desktop display.
  discard warp(d, 0, window, 0, 0, 0, 0, x.cint, y.cint)
  d.XFlush()
  sleep(InputDelayMs)

proc mouseButton(d: Display, window: Window, x, y: int, button: cuint, down: bool) =
  ## Deliver a mouse button or wheel edge using its true window coordinates.
  var event = XEvent(button: XButtonEvent(kind: if down: xeButtonPress else: xeButtonRelease,
    display: d, window: window, root: d.defaultRootWindow,
    pos: ivec2(x.int32, y.int32), button: button, same_screen: 1))
  doAssert sendEvent(d, window, 0, if down: 4 else: 8, addr event) != 0
  d.XFlush()
  sleep(InputDelayMs)

proc waitSize(d: Display, window: Window, width, height: int) =
  ## Wait for the window manager to apply an exact client-size change.
  let deadline = getMonoTime() + initDuration(seconds = WaitSeconds)
  while getMonoTime() < deadline:
    var attributes: XWindowAttributes
    d.XGetWindowAttributes(window, addr attributes)
    if attributes.size.x == width and attributes.size.y == height: return
    sleep(10)
  raise newException(AssertionDefect, "Atlas client did not resize as expected.")

proc focus(d: Display, window: Window) =
  ## Assign and verify focus on the private display before dispatching actions.
  let deadline = getMonoTime() + initDuration(seconds = WaitSeconds)
  var attributes: XWindowAttributes
  while getMonoTime() < deadline:
    d.XGetWindowAttributes(window, addr attributes)
    if attributes.map_state == IsViewable: break
    sleep(10)
  doAssert attributes.map_state == IsViewable,
    "The private window must be viewable before XSetInputFocus."
  d.XSetInputFocus(window, rtRoot)
  d.XFlush()
  sleep(InputDelayMs)
  var
    actual: Window
    revert: RevertTo
  d.XGetInputFocus(addr actual, addr revert)
  doAssert actual == window, "Private display focus did not change."

proc appProcess(binary, rom, trace: string, arguments: string): Process =
  ## Launch only the tested binary with shell-quoted paths and a private trace.
  startProcess(findExe("sh"), args = ["-c", "exec " & quoteShell(binary) & " " &
    quoteShell(rom) & " --trace " & arguments & " > " & quoteShell(trace) & " 2>&1"], options = {})

proc finish(process: Process) =
  ## Reap an owned child even when a test assertion fails.
  if process.running: process.terminate()
  discard process.waitForExit(5000)
  process.close()

proc main() =
  ## Verify real input, resize, focus, fullscreen, clean exit, and idle cache reuse.
  let
    directory = createTempDir("atlas-window-", "")
    binary = absolutePath(getEnv(TestBinaryEnv, "bin/map-browser"))
    rom = absolutePath(if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc")
    xvfb = findExe("Xvfb")
    openbox = findExe("openbox")
    priorDisplay = getEnv("DISPLAY")
  doAssert fileExists(binary), "Build bin/map-browser first."
  doAssert fileExists(rom), "The user's ROM is required."
  doAssert xvfb.len > 0 and openbox.len > 0, "Xvfb and Openbox are required for the isolated window test."
  defer: removeDir(directory)
  defer: putEnv("DISPLAY", priorDisplay)
  let server = startProcess(xvfb, args = ["-displayfd", "1", "-screen", "0",
    "1920x1440x24", "-nolisten", "tcp"], options = {})
  defer: server.finish()
  let displayNumber = server.outputStream.readLine().strip()
  doAssert displayNumber.len > 0 and displayNumber.allCharsInSet({'0' .. '9'})
  let displayName = ":" & displayNumber
  putEnv("DISPLAY", displayName)
  let config = directory / "openbox.xml"
  writeFile(config, "<openbox_config xmlns=\"http://openbox.org/3.4/rc\"><focus><focusNew>yes</focusNew></focus></openbox_config>")
  let manager = startProcess(openbox, args = ["--sm-disable", "--config-file", config], options = {})
  defer: manager.finish()
  discard setErrorHandler(recordXError)
  let display = XOpenDisplay(displayName.cstring)
  doAssert display != nil
  defer: discard closeDisplay(display)
  sleep(200)
  let glCheck = execCmdEx(quoteShell(absolutePath("bin/background-gl-smoke")))
  doAssert glCheck.exitCode == 0, glCheck.output
  echo "Shared GL canvas resize: exact authored pixels and independent contexts passed."
  for arguments in ["--zoom:nan", "--zoom:3", "--zoom:0", "--zoom:16",
      "--frames:0", "--x:-1", "--y:10240", "--flag:xyz=on", "--flag:01A6=yes",
      "--flag:0000=on", "--flag:7FFF=off"]:
    let check = execCmdEx(quoteShell(binary) & " " & quoteShell(rom) & " " & arguments)
    doAssert check.exitCode != 0, "Invalid CLI argument was accepted: " & arguments
  let
    idleTrace = directory / "idle.log"
    idle = appProcess(binary, rom, idleTrace, "--frames:12")
  defer: idle.finish()
  doAssert idle.waitForExit(WaitSeconds * 1000) == 0, readFile(idleTrace)
  doAssert "uiFrames=12 viewportRenders=1" in readFile(idleTrace), readFile(idleTrace)
  let
    flagTrace = directory / "flags.log"
    flagCheck = appProcess(binary, rom, flagTrace,
      "--frames:2 --flag:01A6=on --flag:011F=on --flag:01A6=off --flag:0x0044=on")
  defer: flagCheck.finish()
  doAssert flagCheck.waitForExit(WaitSeconds * 1000) == 0, readFile(flagTrace)
  doAssert state(flagTrace).enabledFlags == "0044,011F", readFile(flagTrace)
  let
    trace = directory / "trace.log"
    process = appProcess(binary, rom, trace, "--frames:1200")
  defer: process.finish()
  let window = display.findWindow()
  display.focus(window)
  waitTrace(trace, "action=startup")
  doAssert state(trace).zoom == 0.0625
  display.tap(window, TabKey)
  waitTrace(trace, "worldpanel=world")
  let beforeFlags = state(trace)
  display.tap(window, DownKey)
  waitTrace(trace, "action=WorldNextFlag")
  doAssert state(trace).worldRow == 1
  display.tap(window, EnterKey)
  waitTrace(trace, "action=ToggleWorldFlag")
  doAssert state(trace).enabledFlags == "000E"
  doAssert state(trace).stateRevision == beforeFlags.stateRevision + 1
  doAssert state(trace).x == beforeFlags.x and state(trace).y == beforeFlags.y
  doAssert state(trace).zoom == beforeFlags.zoom
  display.pointer(window, 80, 430)
  display.mouseButton(window, 80, 430, 5, true)
  display.mouseButton(window, 80, 430, 5, false)
  waitTrace(trace, "action=world-wheel")
  doAssert state(trace).worldScroll == 1
  doAssert state(trace).zoom == beforeFlags.zoom
  display.pointer(window, 80, 680)
  display.mouseButton(window, 80, 680, 1, true)
  display.mouseButton(window, 80, 680, 1, false)
  waitTrace(trace, "action=ResetWorldFlags")
  doAssert state(trace).enabledFlags == "-"
  display.tap(window, EscapeKey)
  waitTrace(trace, "action=ShowInspectPanel")
  doAssert state(trace).worldPanel == "inspect"
  doAssert process.running, "Returning from World must not exit the application."
  display.tap(window, PlusKey)
  waitTrace(trace, "action=ZoomIn")
  let beforePan = state(trace)
  doAssert beforePan.zoom == 0.125
  display.key(window, RightKey, true)
  sleep(120)
  display.key(window, RightKey, false)
  display.tap(window, EnterKey)
  waitTrace(trace, "action=InspectCenter")
  doAssert state(trace).x > beforePan.x + 5
  let focusedState = state(trace)
  let otherWindow = display.XCreateSimpleWindow(display.defaultRootWindow,
    0, 0, 100, 100, 0, 0, 0)
  defer: display.XDestroyWindow(otherWindow)
  display.XMapWindow(otherWindow)
  display.XFlush()
  sleep(InputDelayMs)
  display.focus(otherWindow)
  display.key(window, LeftKey, true)
  sleep(120)
  display.key(window, LeftKey, false)
  sleep(InputDelayMs)
  display.focus(window)
  display.tap(window, EnterKey)
  waitTrace(trace, "action=InspectCenter", 2)
  doAssert abs(state(trace).x - focusedState.x) < 0.01
  display.tap(window, PlusKey)
  waitTrace(trace, "action=ZoomIn", 2)
  let beforeResize = state(trace)
  display.XResizeWindow(window, 1500, 1100)
  display.XFlush()
  display.waitSize(window, 1500, 1100)
  waitTrace(trace, "canvas=1500x1100")
  let larger = state(trace)
  doAssert larger.viewportWidth == 1162 and larger.viewportHeight == 952
  doAssert larger.zoom == beforeResize.zoom
  doAssert abs(larger.x - beforeResize.x) < 0.01
  doAssert abs(larger.y - beforeResize.y) < 0.01
  doAssert larger.selectedX == beforeResize.selectedX and larger.selectedY == beforeResize.selectedY
  # The right-hand part of this map did not exist in the fixed canvas.
  display.pointer(window, 1400, 850)
  display.mouseButton(window, 1400, 850, 1, true)
  display.mouseButton(window, 1400, 850, 1, false)
  waitTrace(trace, "action=pointer")
  let expandedClick = state(trace)
  doAssert abs(expandedClick.selectedX - floor(larger.x + (1400 - 314 - 581) / larger.zoom).int) <= 1
  doAssert abs(expandedClick.selectedY - floor(larger.y + (850 - 108 - 476) / larger.zoom).int) <= 1
  display.XResizeWindow(window, 600, 400)
  display.XFlush()
  display.waitSize(window, 600, 400)
  display.pointer(window, 300, 200)
  display.mouseButton(window, 300, 200, 1, true)
  display.mouseButton(window, 300, 200, 1, false)
  waitTrace(trace, "action=pointer", 2)
  let clicked = state(trace)
  doAssert clicked.selected
  doAssert abs(clicked.selectedX - floor(clicked.x + (600.0 - 314 - 431) / clicked.zoom).int) <= 1
  doAssert abs(clicked.selectedY - floor(clicked.y + (400.0 - 108 - 326) / clicked.zoom).int) <= 1
  display.mouseButton(window, 300, 200, 4, true)
  display.mouseButton(window, 300, 200, 4, false)
  waitTrace(trace, "action=wheel")
  let beforeDrag = state(trace)
  let wheelZoomCorrect = beforeDrag.zoom == clicked.zoom * 2
  display.mouseButton(window, 300, 200, 1, true)
  display.pointer(window, 320, 200)
  display.pointer(window, 330, 200)
  display.mouseButton(window, 330, 200, 1, false)
  waitTrace(trace, "action=pointer", 3)
  let dragged = state(trace)
  doAssert abs(dragged.x - (beforeDrag.x - 60 / beforeDrag.zoom)) < 1, readFile(trace)
  doAssert dragged.selectedX == beforeDrag.selectedX and dragged.selectedY == beforeDrag.selectedY
  display.tap(window, GridKey)
  waitTrace(trace, "action=ToggleGrid")
  doAssert state(trace).grid
  let oldRegion = state(trace).region
  display.tap(window, PageDownKey)
  waitTrace(trace, "action=NextRegion")
  doAssert state(trace).region == oldRegion + 1
  display.tap(window, FullscreenKey)
  waitTrace(trace, "action=ToggleFullscreen")
  display.waitSize(window, 1920, 1440)
  waitTrace(trace, "canvas=1920x1440")
  doAssert state(trace).viewportWidth == 1582
  doAssert state(trace).viewportHeight == 1292
  display.tap(window, HomeKey)
  waitTrace(trace, "action=FitWorld")
  doAssert state(trace).zoom == 0.125
  display.tap(window, FullscreenKey)
  waitTrace(trace, "action=ToggleFullscreen", 2)
  display.waitSize(window, 600, 400)
  display.tap(window, HomeKey)
  waitTrace(trace, "action=FitWorld", 2)
  doAssert state(trace).zoom == 0.0625
  display.key(window, EscapeKey, true)
  doAssert process.waitForExit(5000) == 0, readFile(trace)
  discard sync(display, 0)
  doAssert not xError, "X11 rejected an input or lifecycle operation:" & xErrorDetails
  doAssert wheelZoomCorrect, "One wheel gesture must produce one zoom step.\n" & readFile(trace)
  echo "Pocket Atlas window: CLI flags, World controls, reset, idle cache, pan, zoom, resized selection, drag, grid, regions, focus, fullscreen, and exit passed."

when isMainModule:
  main()
