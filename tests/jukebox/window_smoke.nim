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

proc findWindow(d: Display): Window =
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
          let matches = $name == "Pocket Jukebox"
          XFree(name)
          if matches: return children[i]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Pocket Jukebox did not open its test window.")

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

proc main() =
  ## Exercise real keyboard/mouse input, audio init, resizing, and clean exit off-desktop.
  let
    directory = createTempDir("jukebox-window-", "")
    trace = directory / "trace.log"
    binary = absolutePath("bin/jukebox")
    rom = absolutePath(if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc")
    xvfbPath = findExe("Xvfb")
  doAssert xvfbPath.len > 0, "Xvfb is required for this optional window test."
  defer: removeDir(directory)
  let server = startProcess(xvfbPath, args = ["-displayfd", "1", "-screen", "0",
    "1280x800x24", "-nolisten", "tcp"], options = {})
  defer:
    if server.running: server.terminate()
    discard server.waitForExit(5000)
    server.close()
  let displayName = ":" & server.outputStream.readLine().strip()
  putEnv("DISPLAY", displayName)
  putEnv("ALSOFT_DRIVERS", "null")
  let d = XOpenDisplay(displayName.cstring)
  doAssert d != nil
  defer: discard closeDisplay(d)
  let process = startProcess(findExe("sh"), args = ["-c", "exec " & quoteShell(binary) &
    " " & quoteShell(rom) & " --song:1 --trace > " & quoteShell(trace) & " 2>&1"], options = {})
  defer:
    if process.running: process.terminate()
    discard process.waitForExit(5000)
    process.close()
  let window = findWindow(d)
  d.XSetInputFocus(window, rtRoot)
  d.XFlush()
  waitTrace(trace, "action=PlaySelected selected=1 song=1 state=Playing")
  tap(d, window, 0xFF54) # Down.
  waitTrace(trace, "action=MoveDown selected=2 song=1 state=Playing")
  tap(d, window, 0xFF0D) # Enter.
  waitTrace(trace, "action=PlaySelected selected=2 song=2 state=Playing")
  key(d, window, 0x20, true)
  sleep(500)
  key(d, window, 0x20, false)
  sleep(90)
  waitTrace(trace, "action=TogglePlayback selected=2 song=2 state=Paused")
  doAssert readFile(trace).count("action=TogglePlayback") == 1
  tap(d, window, 0x20)
  waitTrace(trace, "action=TogglePlayback selected=2 song=2 state=Playing")
  tap(d, window, 0xFF57) # End.
  waitTrace(trace, "action=GoLast selected=191")
  tap(d, window, 0xFF50) # Home.
  let movesBeforeWheel = readFile(trace).count("action=MoveDown")
  wheel(d, window)
  doAssert readFile(trace).count("action=MoveDown") > movesBeforeWheel
  tap(d, window, 0xFF50)
  click(d, window, 200, 480)
  waitTrace(trace, "action=StopPlayback selected=1 song=0 state=Stopped")
  click(d, window, 500, 165)
  waitTrace(trace, "action=PlaySelected selected=1 song=1 state=Playing")
  d.XResizeWindow(window, 400, 300)
  d.XFlush()
  sleep(150)
  click(d, window, 250, 103)
  waitTrace(trace, "action=PlaySelected selected=2 song=2 state=Playing")
  let before = readFile(trace).count("action=PlaySelected selected=2 song=2")
  doAssert before == 2, "Resized mouse coordinates did not activate track 2."
  d.XResizeWindow(window, 1000, 600)
  d.XFlush()
  sleep(150)
  click(d, window, 10, 420)
  doAssert readFile(trace).count("action=PlaySelected selected=2 song=2") == before
  key(d, window, 0xFF1B, true) # Escape destroys the window before a release can arrive.
  doAssert process.waitForExit(5000) == 0, readFile(trace)
  doAssert "audioUnderruns=0" in readFile(trace), readFile(trace)
  putEnv("ALSOFT_DRIVERS", "jukebox-no-such-audio-driver")
  let muted = startProcess(binary, args = [rom, "--mute", "--song:3", "--frames:3"],
    options = {poParentStreams})
  defer:
    if muted.running: muted.terminate()
    discard muted.waitForExit(5000)
    muted.close()
  doAssert muted.waitForExit(10000) == 0
  echo "Jukebox window: keyboard/mouse/wheel, resize/letterboxing, no audio underruns, mute and exit passed."

when isMainModule:
  main()
