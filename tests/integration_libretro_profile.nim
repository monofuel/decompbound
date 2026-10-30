import
  std/[algorithm, json, os, osproc, strformat, tempfiles],
  decompbound/rom_pipeline

const
  Frames = 64
  Warmup = 5

proc main() =
  ## Exercise the real profiling host, nested accounting, hashes and lifecycle against both libraries.
  let
    host = absolutePath("bin/libretro-profile")
    cores = [absolutePath("bin/libretro/decompbound_libretro.so"),
      absolutePath("bin/libretro/profile-instrumented.so")]
    directory = createTempDir("profile-test-", "", absolutePath("bin"))
    stagePath = directory / "stages.json"
    variables = ["DECOMPBOUND_PROFILE_OUT", "DECOMPBOUND_PROFILE_WARMUP", "DECOMPBOUND_PROFILE_FRAMES"]
  for path in [host, cores[0], cores[1]]:
    doAssert fileExists(path), "Build with make libretro libretro-profile first: " & path
  var
    previous: array[3, string]
    existed: array[3, bool]
    reports: array[2, JsonNode]
  for index, name in variables:
    existed[index] = existsEnv(name)
    previous[index] = getEnv(name)
  defer:
    for index, name in variables:
      if existed[index]: putEnv(name, previous[index])
      else: delEnv(name)
    removeDir(directory)
  putEnv(variables[0], stagePath)
  putEnv(variables[1], $Warmup)
  putEnv(variables[2], $Frames)
  for index, core in cores:
    let
      path = directory / (&"host-{index}.json")
      command = quoteShellCommand([host, "--core:" & core,
        "--rom:" & resolveGoldBaseromPath(), "--frames:" & $Frames,
        "--warmup:" & $Warmup, "--ds", "--walk", "--hash", "--out:" & path])
      child = execCmdEx(command)
    doAssert child.exitCode == 0, child.output
    reports[index] = parseFile(path)
    doAssert reports[index]["frames"].getInt == Frames
    doAssert reports[index]["video_calls"].getInt == Frames
    doAssert reports[index]["video_width"].getInt == 256
    doAssert reports[index]["video_height"].getInt == 448
    doAssert reports[index]["audio_stereo_frames"].getInt == Frames * 533
    doAssert reports[index]["wall_ns"].len == Frames
    var times: seq[int64]
    for sample in reports[index]["wall_ns"]: times.add(sample.getBiggestInt)
    times.sort()
    doAssert reports[index]["wall_summary_ns"]["max"].getBiggestInt == times[^1]
    doAssert reports[index]["wall_summary_ns"]["p95"].getBiggestInt == times[60]
    doAssert reports[index]["wall_summary_ns"]["p99"].getBiggestInt == times[63]
  doAssert reports[0]["hashes"] == reports[1]["hashes"],
    "Profiling changed video, PCM, WRAM or SRAM behavior."
  let stages = parseFile(stagePath)
  doAssert stages["recordedFrames"].getInt == Frames
  doAssert stages["framesSeen"].getInt == Frames + Warmup
  doAssert stages["metadata"]["coreProfile"].getBool
  doAssert stages["metadata"]["danger"].getBool
  for frame in stages["frames"]:
    var total: int64
    for stage in frame["stagesNs"]: total += stage.getBiggestInt
    doAssert total == frame["wallNs"].getBiggestInt
  echo "Shared-core profiling: callback paths, raw timings, quantiles, exclusive accounting and all hashes passed."

main()
