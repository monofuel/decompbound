import
  std/[json, os, tempfiles, unittest],
  decompbound/core_profile

proc restoreEnvironment(name, previous: string, existed: bool) =
  ## Restore the caller's profiling configuration after a synthetic accounting test.
  if existed: putEnv(name, previous)
  else: delEnv(name)

proc returnedStage(): int =
  ## Exercise a return leaving a nested measurement scope.
  profileStage(SpcExecution): return 7

suite "Optional core profile accounting":
  test "nested scopes preserve behavior, restore ownership and bound recording":
    let
      directory = createTempDir("decompbound-profile-", "")
      path = directory / "timing.json"
      names = ["DECOMPBOUND_PROFILE_OUT", "DECOMPBOUND_PROFILE_WARMUP", "DECOMPBOUND_PROFILE_FRAMES"]
    var
      previous: array[3, string]
      existed: array[3, bool]
    for index, name in names:
      existed[index] = existsEnv(name)
      previous[index] = getEnv(name)
    defer:
      for index, name in names: restoreEnvironment(name, previous[index], existed[index])
      if fileExists(path): removeFile(path)
      removeDir(directory)
    putEnv(names[0], path)
    putEnv(names[1], "1")
    putEnv(names[2], "2")
    resetCoreProfile()
    var calls = 0
    for frame in 0 ..< 5:
      beginCoreProfile()
      profileStage(MainCpu):
        inc calls
        check returnedStage() == 7
        expect ValueError:
          profileStage(AudioDsp): raise newException(ValueError, "Synthetic scope exit.")
        profileStage(Companion): inc calls
      endCoreProfile()
    check calls == 10
    writeCoreProfile()
    when defined(coreProfile):
      let
        bytes = readFile(path)
        report = parseJson(bytes)
      check report["framesSeen"].getInt == 5
      check report["recordedFrames"].getInt == 2
      check report["frames"][0]["index"].getInt == 1
      check report["frames"][1]["index"].getInt == 2
      for frame in report["frames"]:
        var sum: int64
        for stage in frame["stagesNs"]: sum += stage.getBiggestInt
        check sum == frame["wallNs"].getBiggestInt
        check frame["stagesNs"][MainCpu.ord].getBiggestInt > 0
        check frame["stagesNs"][SpcExecution.ord].getBiggestInt > 0
        check frame["stagesNs"][AudioDsp.ord].getBiggestInt > 0
        check frame["stagesNs"][Companion.ord].getBiggestInt > 0
      writeCoreProfile()
      check readFile(path) == bytes
      clearCoreProfile()
      writeCoreProfile()
      check readFile(path) == bytes
      putEnv(names[2], "0")
      expect ValueError: resetCoreProfile()
    else:
      check not fileExists(path)
      putEnv(names[2], "invalid")
      resetCoreProfile()
