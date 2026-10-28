import
  std/[json, monotimes, os, osproc, posix, streams, strutils, tempfiles, times],
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

proc pactl(arguments: openArray[string]): string =
  ## Run a bounded mixer command against the isolated test server only.
  let process = startProcess(findExe("pactl"), args = arguments, options = {poStdErrToStdOut})
  defer:
    if process.running: process.terminate()
    discard process.waitForExit(3000)
    process.close()
  let code = process.waitForExit(3000)
  result = process.outputStream.readAll()
  doAssert code == 0, "pactl " & arguments.join(" ") & ": " & result

proc streamPercent(index: string): string =
  ## Read a stream percentage from pactl's independently formatted volume listing.
  for input in parseJson(pactl(["-f", "json", "list", "sink-inputs"])):
    if $input["index"].getInt == index:
      return input["volume"]["front-left"]["value_percent"].getStr
  raise newException(AssertionDefect, "Missing test stream " & index)

proc streamForPid(pid: int): string =
  ## Resolve a test stream by its exact process, including client-only PID metadata.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    let
      clients = parseJson(pactl(["-f", "json", "list", "clients"]))
      inputs = parseJson(pactl(["-f", "json", "list", "sink-inputs"]))
    for input in inputs:
      let props = input["properties"]
      if props.hasKey("application.process.id") and props["application.process.id"].getStr == $pid:
        return $input["index"].getInt
      for client in clients:
        let clientId = if input["client"].kind == JString: input["client"].getStr else: $input["client"].getInt
        if $client["index"].getInt == clientId and
            client["properties"].hasKey("application.process.id") and
            client["properties"]["application.process.id"].getStr == $pid:
          return $input["index"].getInt
    sleep(20)
  raise newException(AssertionDefect, "No isolated audio stream for PID " & $pid)

proc main() =
  ## Exercise real keyboard/mouse input, audio init, resizing, and clean exit off-desktop.
  let
    directory = createTempDir("jukebox-window-", "")
    trace = directory / "trace.log"
    binary = absolutePath("bin/jukebox")
    rom = absolutePath(if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc")
    xvfbPath = findExe("Xvfb")
    checkMixer = paramCount() > 1 and paramStr(2) == "--system-volume"
  doAssert xvfbPath.len > 0, "Xvfb is required for this optional window test."
  defer: removeDir(directory)
  let server = startProcess(xvfbPath, args = ["-displayfd", "1", "-screen", "0",
    "1280x800x24", "-nolisten", "tcp"], options = {})
  defer:
    if server.running: server.terminate()
    discard server.waitForExit(5000)
    server.close()
  let displayName = ":" & server.outputStream.readLine().strip()
  discard setErrorHandler(recordXError)
  putEnv("DISPLAY", displayName)
  var
    pulseServer, otherStream: Process
  defer:
    for child in [otherStream, pulseServer]:
      if child != nil:
        if child.running: child.terminate()
        discard child.waitForExit(5000)
        child.close()
  if checkMixer:
    doAssert findExe("pulseaudio").len > 0 and findExe("pactl").len > 0
    let socket = directory / "pulse.sock"
    putEnv("DBUS_SESSION_BUS_ADDRESS", "unix:path=" & directory / "unused-dbus")
    pulseServer = startProcess(findExe("pulseaudio"), args = ["--daemonize=no",
      "--use-pid-file=no", "--exit-idle-time=15", "--log-target=file:" & directory / "pulse.log", "-n",
      "--load=module-null-sink sink_name=jukebox_test",
      "--load=module-native-protocol-unix auth-anonymous=1 socket=" & socket], options = {})
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while posix.access(socket.cstring, F_OK) != 0:
      doAssert getMonoTime() < deadline, "Private Pulse server did not start: " & readFile(directory / "pulse.log")
      sleep(20)
    putEnv("PULSE_SERVER", "unix:" & socket)
    putEnv("ALSOFT_DRIVERS", "pulse")
    otherStream = startProcess(findExe("pacat"), args = ["--playback", "--raw"], options = {})
  else:
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
  let mapDeadline = getMonoTime() + initDuration(seconds = 5)
  var attributes: XWindowAttributes
  while true:
    d.XGetWindowAttributes(window, addr attributes)
    if attributes.map_state == IsViewable: break
    doAssert getMonoTime() < mapDeadline, "Jukebox window was never mapped."
    sleep(10)
  d.XSetInputFocus(window, rtRoot)
  d.XFlush()
  discard sync(d, 0)
  doAssert not xError, "X11 rejected focus on the mapped jukebox window."
  waitTrace(trace, "action=PlaySelected selected=1 song=1 state=Playing")
  if checkMixer:
    waitTrace(trace, "systemVolume=100 muted=false")
    let
      mine = streamForPid(process.processID)
      other = streamForPid(otherStream.processID)
    discard pactl(["set-sink-input-volume", other, "23%"])
    discard pactl(["set-sink-input-volume", mine, "37%"])
    waitTrace(trace, "systemVolume=37 muted=false gain=1.00")
    tap(d, window, 0x3D) # Plus/equal.
    waitTrace(trace, "action=Louder selected=1 song=1 state=Playing volume=42")
    doAssert streamPercent(mine) == "42%"
    doAssert streamPercent(other) == "23%"
    discard pactl(["set-sink-input-mute", mine, "1"])
    waitTrace(trace, "systemVolume=42 muted=true")
    discard pactl(["set-sink-input-volume", mine, "45%"])
    waitTrace(trace, "systemVolume=45 muted=true")
    discard pactl(["set-sink-input-mute", mine, "0"])
    waitTrace(trace, "systemVolume=45 muted=false")
    doAssert streamPercent(other) == "23%"
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
  discard sync(d, 0)
  doAssert not xError, "X11 rejected a window/input test request."
  doAssert "audioUnderruns=0" in readFile(trace), readFile(trace)
  if checkMixer: echo "Jukebox volume: external changes, app controls, mute and other-PID isolation passed."
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
