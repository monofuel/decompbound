import
  std/[monotimes, os, osproc, streams, strutils, tempfiles, times],
  vmath,
  windy/platforms/linux/x11/[x, xevent, xlib]

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

type XErrorCallback = proc(d: Display, event: ptr XErrorEvent): cint {.cdecl.}
proc setErrorHandler(callback: XErrorCallback): pointer
    {.cdecl, importc: "XSetErrorHandler", dynlib: libX11.}
proc sync(d: Display, discardEvents: cint): cint {.cdecl, importc: "XSync", dynlib: libX11.}

var xError = false

proc recordXError(d: Display, event: ptr XErrorEvent): cint {.cdecl.} =
  ## Let Nim assertions unwind test resources instead of Xlib calling exit.
  xError = true
  0

proc findWindow(d: Display, title: string): Window =
  ## Find only our player's window on a new isolated Xvfb server.
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while getMonoTime() < deadline:
    var
      root, parent: Window
      children: ptr UncheckedArray[Window]
      count: cuint
    doAssert queryTree(d, d.defaultRootWindow, addr root, addr parent, addr children, addr count) != 0
    try:
      for i in 0 ..< count.int:
        var name: cstring
        if fetchName(d, children[i], addr name) != 0 and name != nil:
          let matches = $name == title
          XFree(name)
          if matches: return children[i]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Pocket Backgrounds did not open window: " & title & ".")

proc waitTrace(path, expected: string) =
  ## Wait for a real app action rather than assuming an input event was consumed.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    if fileExists(path) and expected in readFile(path): return
    sleep(10)
  raise newException(AssertionDefect, "Missing trace: " & expected & "\n" & readFile(path))

proc key(d: Display, window: Window, symbol: culong, down: bool) =
  ## Deliver a key through Windy's X11 backend on the isolated display.
  var event = XEvent(key: XKeyEvent(kind: if down: xeKeyPress else: xeKeyRelease,
    display: d, window: window, root: d.defaultRootWindow,
    keycode: keycode(d, symbol).cuint, same_screen: 1))
  doAssert sendEvent(d, window, 0, if down: 1 else: 2, addr event) != 0
  d.XFlush()

proc tap(d: Display, window: Window, symbol: culong) =
  ## Keep test key edges apart while the app renders its UI.
  key(d, window, symbol, true)
  sleep(90)
  key(d, window, symbol, false)
  sleep(90)

proc click(d: Display, window: Window, x, y: int) =
  ## Move and click through Windy's actual pointer and button event handling.
  discard warp(d, 0, window, 0, 0, 0, 0, x.cint, y.cint)
  d.XFlush()
  sleep(90)
  for down in [true, false]:
    var event = XEvent(button: XButtonEvent(kind: if down: xeButtonPress else: xeButtonRelease,
      display: d, window: window, root: d.defaultRootWindow,
      pos: ivec2(x.int32, y.int32), button: 1, same_screen: 1))
    doAssert sendEvent(d, window, 0, if down: 4 else: 8, addr event) != 0
    d.XFlush()
    sleep(90)

proc wheel(d: Display, window: Window) =
  ## Exercise a full downward wheel gesture, including separately polled edges.
  for down in [true, false]:
    var event = XEvent(button: XButtonEvent(kind: if down: xeButtonPress else: xeButtonRelease,
      display: d, window: window, root: d.defaultRootWindow, button: 5, same_screen: 1))
    doAssert sendEvent(d, window, 0, if down: 4 else: 8, addr event) != 0
    d.XFlush()
    sleep(90)

proc focus(d: Display, window: Window) =
  ## Wait for mapping before assigning focus on a server without a window manager.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  var attributes: XWindowAttributes
  while true:
    d.XGetWindowAttributes(window, addr attributes)
    if attributes.map_state == IsViewable: break
    doAssert getMonoTime() < deadline, "Window was not mapped."
    sleep(10)
  d.XRaiseWindow(window)
  d.XSetInputFocus(window, rtRoot)
  d.XFlush()
  discard sync(d, 0)
  doAssert not xError
  sleep(70)

proc requestClose(d: Display, window: Window) =
  ## Send the same WM_DELETE_WINDOW request as a window-manager close button.
  var event: XEvent
  event.client.kind = xeClientMessage
  event.client.window = window
  event.client.message_type = d.XInternAtom("WM_PROTOCOLS", 0)
  event.client.format = 32
  event.client.data.l[0] = d.XInternAtom("WM_DELETE_WINDOW", 0).clong
  doAssert sendEvent(d, window, 0, 0, addr event) != 0
  d.XFlush()

proc lastFrame(path: string): int =
  ## Read the frame reported by the last actual transport action.
  for line in readFile(path).splitLines:
    for part in line.splitWhitespace:
      if part.startsWith("frame="): result = parseInt(part[6 .. ^1])

proc main() =
  ## Exercise both real windows, input, animation without focus, resize and reopening.
  let
    directory = createTempDir("background-window-", "")
    trace = directory / "trace.log"
    binary = absolutePath("bin/battle-bg")
    rom = absolutePath(if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc")
    xvfb = findExe("Xvfb")
  doAssert xvfb.len > 0, "Xvfb is required."
  defer: removeDir(directory)
  let server = startProcess(xvfb, args = ["-displayfd", "1", "-screen", "0",
    "1920x1080x24", "-nolisten", "tcp"], options = {})
  defer:
    if server.running: server.terminate()
    discard server.waitForExit(5000)
    server.close()
  let displayName = ":" & server.outputStream.readLine().strip()
  putEnv("DISPLAY", displayName)
  discard setErrorHandler(recordXError)
  let d = XOpenDisplay(displayName.cstring)
  doAssert d != nil
  defer: discard closeDisplay(d)
  let process = startProcess(findExe("sh"), args = ["-c", "exec " & quoteShell(binary) &
    " " & quoteShell(rom) & " --enemy:2 --trace > " & quoteShell(trace) & " 2>&1"], options = {})
  defer:
    if process.running: process.terminate()
    discard process.waitForExit(5000)
    process.close()
  let controls = findWindow(d, "Pocket Backgrounds - Controls")
  var preview = findWindow(d, "Pocket Backgrounds - Preview")
  focus(d, preview)
  tap(d, preview, 0x20) # Space pauses from the preview.
  waitTrace(trace, "action=ToggleAnimation enemy=2")
  doAssert lastFrame(trace) > 0
  tap(d, preview, 0x72) # R resets without unpausing.
  waitTrace(trace, "frame=0 paused=true")
  tap(d, preview, 0x2E) # Period steps exactly once.
  waitTrace(trace, "frame=1 paused=true")
  focus(d, controls)
  tap(d, controls, 0xFF54) # Down from controls.
  waitTrace(trace, "action=EnemyDown enemy=3")
  wheel(d, controls)
  waitTrace(trace, "action=EnemyDown enemy=4")
  tap(d, controls, 0xFF50) # Normalize the selection after the wheel gesture.
  for step in 0 ..< 3: tap(d, controls, 0xFF54)
  d.XResizeWindow(controls, 400, 300)
  d.XResizeWindow(preview, 1100, 400)
  d.XFlush()
  sleep(120)
  click(d, controls, 250, 165) # Half-sized play button.
  waitTrace(trace, "action=ToggleAnimation enemy=4")
  doAssert "paused=false" in readFile(trace)
  d.XSetInputFocus(d.defaultRootWindow, rtRoot)
  d.XFlush()
  sleep(350)
  focus(d, preview)
  tap(d, preview, 0x20)
  doAssert lastFrame(trace) >= 12, readFile(trace)
  let pausedFrame = lastFrame(trace)
  for cycle in 0 ..< 3:
    requestClose(d, preview)
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while readFile(trace).count("preview=closed") < cycle + 1:
      doAssert process.running and getMonoTime() < deadline, readFile(trace)
      sleep(10)
    focus(d, controls)
    tap(d, controls, 0x70) # P reopens without resetting time.
    preview = findWindow(d, "Pocket Backgrounds - Preview")
    doAssert lastFrame(trace) == pausedFrame
    focus(d, preview)
    d.XResizeWindow(preview, 100, 100)
    d.XFlush()
    sleep(100)
  requestClose(d, controls)
  doAssert process.waitForExit(5000) == 0, readFile(trace)
  discard sync(d, 0)
  doAssert not xError, "X11 rejected a lifecycle/input request."
  let pixels = startProcess(absolutePath("bin/background-gl-smoke"), options = {poParentStreams})
  defer:
    if pixels.running: pixels.terminate()
    discard pixels.waitForExit(5000)
    pixels.close()
  doAssert pixels.waitForExit(10000) == 0
  echo "Background windows: both-window input, resized mouse, unfocused clock, close/reopen and pixel crop passed."

when isMainModule: main()
