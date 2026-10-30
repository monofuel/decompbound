when defined(coreProfile):
  import
    std/[json, monotimes, os, strutils],
    ./build_info

type
  CoreProfileStage* = enum
    CoreOther, MainCpu, MainCpuWait, VideoScanline, VideoSprites, VideoForeground,
    ApuOther, SpcExecution, AudioDsp, Companion, PixelPacking,
    InputCallback, VideoCallback, AudioCallback, SystemTasks

when defined(coreProfile):
  type
    CoreProfileFrame = object
      index: int64
      wallNs: int64
      stagesNs: array[CoreProfileStage, int64]

  const
    ProfileSchema = 1
    DefaultWarmupFrames = 120
    DefaultRecordedFrames = 6000
    MaximumRecordedFrames = 100_000
    MaximumWarmupFrames = 1_000_000

  var
    configured, frameOpen, frameActive: bool
    outputPath: string
    warmupFrames, maximumFrames: int
    framesSeen: int64
    frameStartedNs, stageStartedNs: int64
    activeStage: CoreProfileStage
    stageTicks: array[CoreProfileStage, int64]
    frames: seq[CoreProfileFrame]

  proc resetCoreProfile*() =
    ## Start a bounded recording configured explicitly through profiling environment variables.
    if frameOpen:
      raise newException(ValueError, "Cannot reset a core profile during a frame.")
    let
      warmup = parseInt(getEnv("DECOMPBOUND_PROFILE_WARMUP", $DefaultWarmupFrames))
      maximum = parseInt(getEnv("DECOMPBOUND_PROFILE_FRAMES", $DefaultRecordedFrames))
    if warmup notin 0 .. MaximumWarmupFrames:
      raise newException(ValueError, "Core profile warmup must be inside 0..1000000.")
    if maximum notin 1 .. MaximumRecordedFrames:
      raise newException(ValueError, "Core profile frame limit must be inside 1..100000.")
    outputPath = getEnv("DECOMPBOUND_PROFILE_OUT")
    warmupFrames = warmup
    maximumFrames = maximum
    framesSeen = 0
    frameActive = false
    stageTicks = default(array[CoreProfileStage, int64])
    frames = newSeqOfCap[CoreProfileFrame](maximumFrames)
    configured = true

  proc beginCoreProfile*() =
    ## Open one frame, collecting stage clocks until the recording limit is reached.
    if frameOpen:
      raise newException(ValueError, "A core profile frame is already open.")
    if not configured: resetCoreProfile()
    frameOpen = true
    frameActive = frames.len < maximumFrames
    if frameActive:
      stageTicks = default(array[CoreProfileStage, int64])
      activeStage = CoreOther
      frameStartedNs = getMonoTime().ticks
      stageStartedNs = frameStartedNs

  proc enterProfileStage(stage: CoreProfileStage): CoreProfileStage {.inline.} =
    ## Attribute elapsed parent work before transferring the clock to a nested stage.
    let now = getMonoTime().ticks
    stageTicks[activeStage] += now - stageStartedNs
    result = activeStage
    activeStage = stage
    stageStartedNs = now

  proc leaveProfileStage(parent: CoreProfileStage) {.inline.} =
    ## Finish nested work and restore its parent without charging the parent twice.
    let now = getMonoTime().ticks
    stageTicks[activeStage] += now - stageStartedNs
    activeStage = parent
    stageStartedNs = now

  template profileStage*(stage: CoreProfileStage, body: untyped) =
    ## Measure exclusive stage work and restore nesting even across returns or exceptions.
    if frameActive:
      let parentStage {.gensym.} = enterProfileStage(stage)
      try:
        body
      finally:
        leaveProfileStage(parentStage)
    else:
      body

  proc endCoreProfile*() =
    ## Close a frame, excluding warmup frames and bounding retained timing samples.
    if not frameOpen:
      raise newException(ValueError, "No core profile frame is open.")
    if frameActive:
      let now = getMonoTime().ticks
      stageTicks[activeStage] += now - stageStartedNs
      if framesSeen >= warmupFrames.int64:
        frames.add(CoreProfileFrame(index: framesSeen,
          wallNs: now - frameStartedNs, stagesNs: stageTicks))
    inc framesSeen
    frameOpen = false
    frameActive = false

  proc writeCoreProfile*() =
    ## Write only timing/provenance JSON to the explicit output or print a short summary.
    if frameOpen:
      raise newException(ValueError, "Cannot write a core profile during a frame.")
    if not configured: return
    if outputPath.len == 0:
      echo "Core profile: ", frames.len, " recorded frames; ", warmupFrames,
        " warmup frames; set DECOMPBOUND_PROFILE_OUT for timing JSON."
      return
    var
      names = newJArray()
      samples = newJArray()
      totals = default(array[CoreProfileStage, int64])
      totalWallNs: int64
    for stage in CoreProfileStage: names.add(%($stage))
    for frame in frames:
      var stageValues = newJArray()
      for stage in CoreProfileStage:
        stageValues.add(%frame.stagesNs[stage])
        totals[stage] += frame.stagesNs[stage]
      totalWallNs += frame.wallNs
      samples.add(%*{"index": frame.index, "wallNs": frame.wallNs,
        "stagesNs": stageValues})
    var totalValues = newJArray()
    for stage in CoreProfileStage: totalValues.add(%totals[stage])
    let
      document = %*{
        "schema": ProfileSchema,
        "metadata": {
          "buildCommit": BuildCommit,
          "buildDirty": BuildDirty,
          "nimVersion": NimVersion,
          "danger": defined(danger),
          "release": defined(release),
          "coreProfile": true
        },
        "warmupFrames": warmupFrames,
        "maximumFrames": maximumFrames,
        "framesSeen": framesSeen,
        "recordedFrames": frames.len,
        "stageNames": names,
        "totalWallNs": totalWallNs,
        "totalsNs": totalValues,
        "frames": samples
      }
      directory = outputPath.parentDir
    if directory.len > 0: createDir(directory)
    writeFile(outputPath, $document & "\n")

  proc clearCoreProfile*() =
    ## Release retained timing buffers before the shared library is unloaded.
    if frameOpen:
      raise newException(ValueError, "Cannot clear a core profile during a frame.")
    frames = @[]
    outputPath = ""
    configured = false
    frameActive = false

else:
  template profileStage*(stage: CoreProfileStage, body: untyped) =
    ## Preserve only the original body in builds without core profiling.
    body

  proc resetCoreProfile*() {.inline.} =
    ## Preserve the profiling interface without runtime work in normal builds.
    discard

  proc beginCoreProfile*() {.inline.} =
    ## Preserve the profiling interface without runtime work in normal builds.
    discard

  proc endCoreProfile*() {.inline.} =
    ## Preserve the profiling interface without runtime work in normal builds.
    discard

  proc writeCoreProfile*() {.inline.} =
    ## Preserve the profiling interface without runtime work in normal builds.
    discard

  proc clearCoreProfile*() {.inline.} =
    ## Preserve the profiling interface without runtime work in normal builds.
    discard
