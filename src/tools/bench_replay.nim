## Headless benchmark + referee. Replays a cadence-emu tape from its pinned
## start state with rendering on, times it, and folds running hashes of the
## rendered frame, the frame's APU samples and WRAM into a DBREF1 golden file
## (see bench_ref.nim). Later runs compare against the golden and fail on the
## first divergence, so an optimization is proven behaviour-preserving when
## the same tape produces the same ref on every host and build.
##
## Usage:
##   nim r src/tools/bench_replay.nim <rom> <session-dir | tape.tas | start.png> [options]
##     --frames N        replay TAS frames 0..N-1 (default: last recorded frame)
##     --ref PATH        golden file (default: <tape stem>.ref beside the tape)
##     --write-ref       write the golden instead of comparing
##     --accept-image    compare; image drift rewrites the ref, audio/wram drift fails
##     --no-ref          timing only
##     --no-render       skip PPU work (isolates render cost by subtraction)
##     --hash-every N    fold image/audio into the running hash every N frames (default 1)
##     --label NAME      label for the results row
##     --out FILE        append a TSV results row to FILE
##     --frame-times FILE  write "frame\tms" per emulated frame (find slow scenes)
##     --state-at N FILE   write the machine state after frame N to FILE (.state),
##                       so a scene found by --frame-times can be benchmarked alone
##
## The tape's `chk` checkpoints are verified during the run as well (applyTas).

import
  std/[monotimes, options, os, strformat, strutils, times],
  pixie,
  zippy/crc,
  ../decompbound/[bench_ref, build_info, cpu, frame_step, png_state, ppu, replay,
    replay_run, save_state, snesbus]

const
  RowEvery = ReplayChkInterval
  Usage = "Usage: nim r src/tools/bench_replay.nim <rom> <session-dir|tape.tas|start.png|start.state> " &
    "[--frames N] [--ref PATH] [--write-ref] [--accept-image] [--no-ref] " &
    "[--no-render] [--hash-every N] [--label NAME] [--out FILE] [--frame-times FILE] [--state-at N FILE]"

type
  Options = object
    romPath: string
    target: string
    frames: int
    refPath: string
    writeRef: bool
    acceptImage: bool
    noRef: bool
    noRender: bool
    hashEvery: int
    label: string
    outPath: string
    frameTimesPath: string
    stateAtFrame: int
    stateAtPath: string

proc parseOptions(): Options =
  ## Parse the command line; exits with usage on error.
  var argBase = 1
  if paramCount() >= 1 and paramStr(1) == "--":
    argBase = 2
  if paramCount() < argBase + 1:
    echo Usage
    quit(1)
  result.romPath = paramStr(argBase)
  result.target = paramStr(argBase + 1)
  result.frames = -1
  result.hashEvery = 1
  result.stateAtFrame = -1
  var i = argBase + 2
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--frames" and i < paramCount():
      inc i
      result.frames = parseInt(paramStr(i))
    elif arg == "--ref" and i < paramCount():
      inc i
      result.refPath = paramStr(i)
    elif arg == "--write-ref":
      result.writeRef = true
    elif arg == "--accept-image":
      result.acceptImage = true
    elif arg == "--no-ref":
      result.noRef = true
    elif arg == "--no-render":
      result.noRender = true
    elif arg == "--hash-every" and i < paramCount():
      inc i
      result.hashEvery = parseInt(paramStr(i))
    elif arg == "--label" and i < paramCount():
      inc i
      result.label = paramStr(i)
    elif arg == "--state-at" and i + 1 < paramCount():
      inc i
      result.stateAtFrame = parseInt(paramStr(i))
      inc i
      result.stateAtPath = paramStr(i)
    elif arg == "--frame-times" and i < paramCount():
      inc i
      result.frameTimesPath = paramStr(i)
    elif arg == "--out" and i < paramCount():
      inc i
      result.outPath = paramStr(i)
    else:
      echo "Unknown arg: ", arg
      echo Usage
      quit(1)
    inc i
  if result.hashEvery < 1:
    echo "--hash-every must be >= 1"
    quit(1)

proc pickSessionTape(sessionDir: string): string =
  ## The largest .tas in a session dir (the main tape).
  var best = ""
  var bestLen = -1
  for kind, path in walkDir(sessionDir):
    if kind != pcFile or not path.endsWith(".tas"):
      continue
    let n = getFileSize(path).int
    if n > bestLen:
      bestLen = n
      best = path
  if best.len == 0:
    echo "ERROR: no .tas in ", sessionDir
    quit(1)
  best

proc resolveStartState(tapePath: string, header: ReplayHeader): string =
  ## Locate the tape's start state: <stem>_start.state beside it, else the
  ## header's start_state reference relative to the cwd or the tape's dir.
  let stem = tapePath[0 ..< tapePath.len - 4]
  let beside = stem & "_start.state"
  if fileExists(beside):
    return beside
  if header.startStateRef.len > 0:
    if fileExists(header.startStateRef):
      return header.startStateRef
    let rel = tapePath.parentDir / header.startStateRef.extractFilename
    if fileExists(rel):
      return rel
  echo "ERROR: start state not found for ", tapePath
  quit(1)

proc loadStateFile(path: string, snes: SnesBus, cpu: var Cpu) =
  ## Restore a .state file or the ebSt chunk of an F12 PNG into the machine.
  let bytes = cast[seq[uint8]](readFile(path))
  if path.endsWith(".png"):
    let st = extractState(bytes)
    if st.isNone:
      echo "ERROR: no embedded state in ", path
      quit(1)
    deserializeState(cast[seq[byte]](st.get), snes, cpu)
  else:
    deserializeState(cast[seq[byte]](bytes), snes, cpu)

proc appendResult(opts: Options, tape: string, frames: int, wallS, hashS: float,
    refStatus: string) =
  ## Append one TSV row to the results file, writing the header if new.
  if opts.outPath.len == 0:
    return
  let fresh = not fileExists(opts.outPath)
  createDir(opts.outPath.parentDir)
  let f = open(opts.outPath, fmAppend)
  if fresh:
    f.writeLine("utc\thost\tlabel\tbuild\ttape\tframes\twall_s\tfps\tx_realtime\thash_s\tref_status")
  let fps = if wallS > 0: frames.float / wallS else: 0.0
  var host = ""
  try:
    host = readFile("/etc/hostname").strip()
  except IOError:
    host = "unknown"
  f.writeLine(&"{now().utc.format(\"yyyy-MM-dd'T'HH:mm:ss'Z'\")}\t{host}\t{opts.label}\t" &
    &"{buildLabel()}\t{tape.extractFilename}\t{frames}\t{wallS:.3f}\t{fps:.2f}\t" &
    &"{fps / 60.0:.3f}\t{hashS:.3f}\t{refStatus}")
  f.close()

proc main() =
  ## Load, replay with hashing, compare or write the golden, report timing.
  let opts = parseOptions()

  var tapePath = opts.target
  if dirExists(opts.target):
    tapePath = pickSessionTape(opts.target)
  var startPath = ""
  if tapePath.endsWith(".png") or tapePath.endsWith(".state"):
    startPath = tapePath
    tapePath = ""
  var header: ReplayHeader
  var deltas: seq[ReplayDelta]
  if tapePath.len > 0:
    (header, deltas) = replay.parseReplay(tapePath)
    if isLegacyReplay(header):
      echo "ERROR: legacy TAS (no cadence emu): ", tapePath
      quit(1)
    startPath = resolveStartState(tapePath, header)

  let rom = frame_step.readRomFile(opts.romPath)
  let romHash = romHashOf(rom)
  if tapePath.len > 0 and header.romHash != 0 and header.romHash != romHash:
    echo &"ERROR: tape ROM hash 0x{header.romHash:08X} != ROM 0x{romHash:08X}"
    quit(1)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  loadStateFile(startPath, snes, cpu)

  var frames = opts.frames
  if frames < 0:
    frames = if tapePath.len > 0: lastRecordedFrame(header, deltas) + 1 else: 3600
  let tapeName = if tapePath.len > 0: tapePath.extractFilename else: startPath.extractFilename
  let tapeCrc = if tapePath.len > 0: crc32(readFile(tapePath)) else: 0'u32
  var refPath = opts.refPath
  if refPath.len == 0:
    let stemSource = if tapePath.len > 0: tapePath else: startPath
    refPath = stemSource[0 ..< stemSource.len - 4] & ".ref"

  var golden: BenchRef
  var haveGolden = false
  if not opts.noRef and not opts.writeRef:
    if not fileExists(refPath):
      echo "ERROR: no golden at ", refPath, " (run with --write-ref first, or --no-ref)"
      quit(1)
    golden = parseBenchRef(refPath)
    haveGolden = true
    if golden.romHash != romHash:
      echo &"ERROR: golden ROM hash 0x{golden.romHash:08x} != supplied ROM 0x{romHash:08x}"
      quit(1)
    if golden.tapeCrc != tapeCrc:
      echo &"ERROR: golden was made for a different tape (crc 0x{golden.tapeCrc:08x} vs 0x{tapeCrc:08x})"
      quit(1)
    if golden.hashEvery != opts.hashEvery:
      echo &"ERROR: golden hash_every {golden.hashEvery} != requested {opts.hashEvery}"
      quit(1)
    if frames > golden.frames:
      echo &"ERROR: golden covers {golden.frames} frames, run asks for {frames}"
      quit(1)
    if opts.acceptImage and frames != golden.frames:
      echo "ERROR: accepting image changes requires the complete golden workload"
      quit(1)
    if frames < golden.frames and frames mod RowEvery != 0:
      echo &"ERROR: a prefix run must be a multiple of {RowEvery} frames to line up with golden rows"
      quit(1)

  echo &"ROM: {opts.romPath} hash=0x{romHash:08X}"
  echo &"tape: {tapeName} start: {startPath} frames: {frames} render: {not opts.noRender}"

  var image: Image = nil
  if not opts.noRender:
    image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var pcm: FramePcm
  var imgRun = HashSeed
  var audRun = HashSeed
  var rows: seq[BenchRow] = @[]
  var hashNs: int64 = 0
  var imageDrift = false
  var mismatch: Option[RefMismatch]

  var frameTimes: File
  var frameStart = getMonoTime()
  if opts.frameTimesPath.len > 0:
    frameTimes = open(opts.frameTimesPath, fmWrite)
    frameTimes.writeLine("frame\tms")

  proc onFrame(snes: SnesBus, tf: int) =
    ## Fold this frame's hashes and compare a row at every checkpoint interval.
    if frameTimes != nil:
      let now = getMonoTime()
      frameTimes.writeLine($tf & "\t" & formatFloat((now - frameStart).inNanoseconds.float / 1e6, ffDecimal, 3))
      frameStart = now
    if tf == opts.stateAtFrame:
      writeFile(opts.stateAtPath, cast[string](serializeState(snes, cpu)))
      echo "state after frame ", tf, " -> ", opts.stateAtPath
    if tf mod opts.hashEvery == 0:
      let t0 = getMonoTime()
      if image != nil:
        imgRun = foldHash(imgRun, crc32(image.data[0].addr, image.data.len * sizeof(image.data[0])))
      audRun = foldHash(audRun, crc32(pcm[0].addr, sizeof(pcm)))
      hashNs += (getMonoTime() - t0).inNanoseconds
    if (tf + 1) mod RowEvery == 0 or tf + 1 == frames:
      let row = BenchRow(frame: tf, image: imgRun, audio: audRun, wram: wramHash(snes))
      rows.add(row)
      if haveGolden and mismatch.isNone:
        let idx = rows.len - 1
        if idx >= golden.rows.len:
          mismatch = some(RefMismatch(frame: tf, fields: @["extra-row"], got: row))
        else:
          var fields = compareRow(golden.rows[idx], row)
          if opts.acceptImage and fields == @["image"]:
            imageDrift = true
            fields = @[]
          if fields.len > 0:
            mismatch = some(RefMismatch(frame: tf, fields: fields,
              want: golden.rows[idx], got: row))
        if mismatch.isSome:
          echo describe(mismatch.get)
          quit(1)

  let t0 = getMonoTime()
  let steps = applyTas(snes, cpu, deltas, frames - 1, checkpoints = header.checkpoints,
    onFrame = onFrame, image = image, pcm = addr pcm)
  let wallS = (getMonoTime() - t0).inNanoseconds.float / 1e9
  let hashS = hashNs.float / 1e9
  if steps != frames:
    echo &"ERROR: emulator stopped after {steps} of {frames} frames"
    quit(1)

  var refStatus = "none"
  let result = BenchRef(tape: tapeName, tapeCrc: tapeCrc, romHash: romHash,
    frames: frames, hashEvery: opts.hashEvery, build: buildLabel(), rows: rows)
  if opts.writeRef or (opts.acceptImage and imageDrift):
    writeBenchRef(refPath, result)
    refStatus = if opts.writeRef: "written" else: "image-accepted"
    echo &"ref written: {refPath} ({rows.len} rows)"
  elif haveGolden:
    let expectRows = if frames == golden.frames: golden.rows.len else: frames div RowEvery
    if rows.len != expectRows:
      echo &"MISMATCH: expected {expectRows} rows from the golden, run produced {rows.len}"
      quit(1)
    refStatus = "OK"
    let scope = if frames == golden.frames: "full" else: &"prefix {frames}/{golden.frames}"
    echo &"ref OK ({scope}): {refPath} ({rows.len} rows)"

  let fps = if wallS > 0: frames.float / wallS else: 0.0
  echo &"frames {frames} wall_s {wallS:.3f} fps {fps:.2f} x_realtime {fps / 60.0:.3f} hash_s {hashS:.3f}"
  echo &"final wram_hash=0x{wramHash(snes):08x} image={imgRun:08x} audio={audRun:08x}"
  appendResult(opts, tapeName, frames, wallS, hashS, refStatus)

when isMainModule:
  main()
