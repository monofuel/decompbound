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

var
  xError = false
  modifiers: cuint

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
          let matches = $name == "Pocket Bestiary"
          XFree(name)
          if matches: return children[i]
    finally:
      if children != nil: XFree(children)
    sleep(10)
  raise newException(IOError, "Pocket Bestiary did not open its test window.")

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
    keycode: keycode(d, symbol).cuint, state: modifiers, same_screen: 1))
  doAssert sendEvent(d, window, 0, if down: 1 else: 2, addr event) != 0
  d.XFlush()
  if symbol in [0xFFE3.culong, 0xFFE4.culong]:
    if down: modifiers = modifiers or ControlMask.cuint
    else: modifiers = modifiers and not ControlMask.cuint

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

proc streamMuted(index: string): bool =
  ## Read actual stream mute state from the server's independent JSON listing.
  for input in parseJson(pactl(["-f", "json", "list", "sink-inputs"])):
    if $input["index"].getInt == index: return input["mute"].getBool
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

proc focus(d: Display, window: Window) =
  ## Focus a mapped test window on the isolated display without a desktop WM.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  var attributes: XWindowAttributes
  while true:
    d.XGetWindowAttributes(window, addr attributes)
    if attributes.map_state == IsViewable: break
    doAssert getMonoTime() < deadline, "Bestiary window was not mapped."
    sleep(10)
  d.XRaiseWindow(window)
  d.XSetInputFocus(window, rtRoot)
  d.XFlush()
  discard sync(d, 0)
  doAssert not xError
  sleep(70)

proc text(d: Display, window: Window, value: string) =
  ## Send quick real key events so a typed query settles before theme debounce.
  for c in value:
    key(d, window, c.ord.culong, true)
    sleep(6)
    key(d, window, c.ord.culong, false)
    sleep(6)
  sleep(80)

proc clearSearch(d: Display, window: Window) =
  ## Select and clear the query through the app's actual Ctrl+A shortcut.
  key(d, window, 0xFFE3, true)
  tap(d, window, 0x61)
  key(d, window, 0xFFE3, false)
  sleep(80)

proc lastNumber(path, field: string): int64 =
  ## Read a numeric diagnostic from the latest real app action.
  for line in readFile(path).splitLines:
    if not line.startsWith("action="): continue
    for part in line.splitWhitespace:
      if part.startsWith(field & "="): result = parseBiggestInt(part[field.len + 1 .. ^1])

proc main() =
  ## Exercise real automatic music, mixer controls, search, resize and lifecycle off-desktop.
  let
    directory = createTempDir("bestiary-window-", "")
    trace = directory / "trace.log"
    binary = absolutePath("bin/bestiary")
    romPath = absolutePath(if paramCount() > 0: paramStr(1) else: "bin/Earthbound (U) [!].smc")
    rom = readFile(romPath)
    xvfb = findExe("Xvfb")
  doAssert xvfb.len > 0 and findExe("pulseaudio").len > 0 and findExe("pactl").len > 0
  var first = 0
  for id in 1..229:
    let song = rom[0x159589 + id * 0x5E + 0x37].ord
    if song > 0 and song == rom[0x159589 + (id + 1) * 0x5E + 0x37].ord:
      first = id
      break
  doAssert first > 0, "No neighboring same-theme entries to test."
  let initialSong = rom[0x159589 + first * 0x5E + 0x37].ord
  var other = 0
  for id in 1..230:
    let song = rom[0x159589 + id * 0x5E + 0x37].ord
    if song > 0 and song != initialSong:
      other = id
      break
  doAssert other > 0
  let otherSong = rom[0x159589 + other * 0x5E + 0x37].ord
  defer: removeDir(directory)
  let server = startProcess(xvfb, args = ["-displayfd", "1", "-screen", "0",
    "1280x900x24", "-nolisten", "tcp"], options = {})
  defer:
    if server.running: server.terminate()
    discard server.waitForExit(5000)
    server.close()
  let displayName = ":" & server.outputStream.readLine().strip()
  putEnv("DISPLAY", displayName)
  putEnv("DBUS_SESSION_BUS_ADDRESS", "unix:path=" & directory / "unused-dbus")
  let socket = directory / "pulse.sock"
  let pulse = startProcess(findExe("pulseaudio"), args = ["--daemonize=no",
    "--use-pid-file=no", "--exit-idle-time=30", "--log-target=file:" & directory / "pulse.log", "-n",
    "--load=module-null-sink sink_name=bestiary_test",
    "--load=module-native-protocol-unix auth-anonymous=1 socket=" & socket], options = {})
  defer:
    if pulse.running: pulse.terminate()
    discard pulse.waitForExit(5000)
    pulse.close()
  let pulseDeadline = getMonoTime() + initDuration(seconds = 5)
  while posix.access(socket.cstring, F_OK) != 0:
    doAssert getMonoTime() < pulseDeadline, "Private audio server did not start."
    sleep(20)
  putEnv("PULSE_SERVER", "unix:" & socket)
  putEnv("ALSOFT_DRIVERS", "pulse")
  let unrelated = startProcess(findExe("pacat"), args = ["--playback", "--raw"], options = {})
  defer:
    if unrelated.running: unrelated.terminate()
    discard unrelated.waitForExit(5000)
    unrelated.close()
  discard setErrorHandler(recordXError)
  let d = XOpenDisplay(displayName.cstring)
  doAssert d != nil
  defer: discard closeDisplay(d)
  let process = startProcess(findExe("sh"), args = ["-c", "exec " & quoteShell(binary) &
    " " & quoteShell(romPath) & " --enemy:" & $first & " --trace > " & quoteShell(trace) & " 2>&1"], options = {})
  defer:
    if process.running: process.terminate()
    discard process.waitForExit(5000)
    process.close()
  let window = findWindow(d)
  focus(d, window)
  waitTrace(trace, "theme=start song=" & $initialSong)
  let starts = readFile(trace).count("theme=start")
  tap(d, window, 0xFF54)
  waitTrace(trace, "action=EnemyDown enemy=" & $(first + 1))
  sleep(250)
  doAssert readFile(trace).count("theme=start") == starts, readFile(trace)
  let mine = streamForPid(process.processID)
  let theirs = streamForPid(unrelated.processID)
  discard pactl(["set-sink-input-volume", theirs, "23%"])
  discard pactl(["set-sink-input-volume", mine, "37%"])
  waitTrace(trace, "systemVolume=37 muted=false")
  tap(d, window, 0x3D)
  doAssert streamPercent(mine) == "42%"
  doAssert streamPercent(theirs) == "23%"
  tap(d, window, 0x6D)
  doAssert streamMuted(mine)
  doAssert not streamMuted(theirs)
  discard pactl(["set-sink-input-mute", mine, "0"])
  waitTrace(trace, "systemVolume=42 muted=false")
  tap(d, window, 0x20)
  waitTrace(trace, "paused=true")
  click(d, window, 80, 130)
  text(d, window, $other)
  waitTrace(trace, "query=" & $other & " results=1")
  waitTrace(trace, "theme=start song=" & $otherSong & " paused=true playerState=Paused")
  let pauses = readFile(trace).count("action=PauseBoth")
  clearSearch(d, window)
  text(d, window, "mmmmzzzz")
  waitTrace(trace, "query=mmmmzzzz results=0")
  doAssert readFile(trace).count("action=ToggleMusicMute") == 1
  doAssert readFile(trace).count("action=PauseBoth") == pauses
  key(d, window, 0xFF1B, true)
  sleep(300)
  key(d, window, 0xFF1B, false)
  sleep(70)
  doAssert process.running, "A held Escape left search and then incorrectly quit."
  click(d, window, 80, 130)
  clearSearch(d, window)
  text(d, window, "1")
  tap(d, window, 0xFF0D)
  d.XResizeWindow(window, 480, 360)
  d.XFlush()
  sleep(120)
  click(d, window, 42, 342)
  waitTrace(trace, "action=PauseBoth enemy=1")
  doAssert readFile(trace).count("action=PauseBoth") == pauses + 1
  let beforeVisual = lastNumber(trace, "frame")
  let beforeMusic = lastNumber(trace, "musicFrame")
  d.XSetInputFocus(d.defaultRootWindow, rtRoot)
  d.XFlush()
  sleep(300)
  focus(d, window)
  tap(d, window, 0x20)
  waitTrace(trace, "paused=true")
  doAssert lastNumber(trace, "frame") >= beforeVisual + 12, readFile(trace)
  doAssert lastNumber(trace, "musicFrame") > beforeMusic + 3200, readFile(trace)
  key(d, window, 0xFF1B, true)
  doAssert process.waitForExit(5000) == 0, readFile(trace)
  doAssert "audioUnderruns=0" in readFile(trace), readFile(trace)
  discard sync(d, 0)
  doAssert not xError
  let outputCheck = startProcess(absolutePath("bin/bestiary-output-smoke"), args = [romPath], options = {poParentStreams})
  defer:
    if outputCheck.running: outputCheck.terminate()
    discard outputCheck.waitForExit(5000)
    outputCheck.close()
  doAssert outputCheck.waitForExit(10000) == 0
  putEnv("ALSOFT_DRIVERS", "bestiary-no-such-driver")
  let silent = startProcess(binary, args = [romPath, "--mute", "--frames:3"], options = {poParentStreams})
  defer:
    if silent.running: silent.terminate()
    discard silent.waitForExit(5000)
    silent.close()
  doAssert silent.waitForExit(10000) == 0
  echo "Bestiary window: same-song continuity, automatic themes, search, coupled pause, mixer/mute isolation, resize and silent startup passed."

when isMainModule: main()
