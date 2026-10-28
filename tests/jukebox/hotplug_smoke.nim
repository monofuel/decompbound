import
  std/[monotimes, os, osproc, tempfiles, times],
  paddy

{.compile: "virtual_pad.c".}

proc createPad(name: cstring): cint {.cdecl, importc: "jukebox_test_pad_create".}
proc destroyPad(fd: cint) {.cdecl, importc: "jukebox_test_pad_destroy".}

proc poller(name, trace: string) =
  ## Observe a virtual controller through Paddy across removal and reconnection.
  initGamepads()
  defer: closeGamepads()
  let deadline = getMonoTime() + initDuration(seconds = 25)
  var phase = 0
  while getMonoTime() < deadline:
    let pads = pollGamepads()
    var connected = false
    for pad in pads:
      if pad.name == name:
        connected = true
        doAssert pad.buttons == 0, "A new controller retained pressed buttons."
    if phase == 0 and connected:
      writeFile(trace, "connected")
      phase = 1
    elif phase == 1 and not connected:
      writeFile(trace, "disconnected")
      phase = 2
    elif phase == 2 and connected:
      writeFile(trace, "reconnected")
      phase = 3
    elif phase == 3 and not connected:
      writeFile(trace, "complete")
      return
    sleep(2)
  raise newException(AssertionDefect, "Controller poller did not finish hotplug cycle.")

proc waitFor(trace, expected: string, child: Process) =
  ## Bound each hardware transition so a dependency polling hang fails the test.
  let deadline = getMonoTime() + initDuration(seconds = 8)
  while getMonoTime() < deadline:
    if fileExists(trace) and readFile(trace) == expected: return
    doAssert child.running, "Paddy poller crashed while waiting for " & expected
    sleep(10)
  raise newException(AssertionDefect, "Paddy hotplug timeout: " & expected)

proc main() =
  ## Create a silent virtual gamepad and destroy it while a child polls Paddy.
  if paramCount() == 3 and paramStr(1) == "--poller":
    poller(paramStr(2), paramStr(3))
    return
  let
    directory = createTempDir("jukebox-hotplug-", "")
    trace = directory / "state"
    name = "decompbound-hotplug-" & $getCurrentProcessId()
  defer: removeDir(directory)
  var fd = createPad(name.cstring)
  if fd < 0: raiseOSError(osLastError(), "Cannot create test gamepad through /dev/uinput")
  defer: destroyPad(fd)
  let child = startProcess(getAppFilename(), args = ["--poller", name, trace],
    options = {poParentStreams})
  defer:
    if child.running: child.terminate()
    discard child.waitForExit(5000)
    child.close()
  waitFor(trace, "connected", child)
  destroyPad(fd)
  fd = -1
  waitFor(trace, "disconnected", child)
  fd = createPad(name.cstring)
  if fd < 0: raiseOSError(osLastError(), "Cannot reconnect test gamepad")
  waitFor(trace, "reconnected", child)
  destroyPad(fd)
  fd = -1
  waitFor(trace, "complete", child)
  doAssert child.waitForExit(5000) == 0
  echo "Paddy: virtual controller attach, unplug, reconnect, second unplug passed."

when isMainModule:
  main()
