## Compare separately compiled renderers over private captures without retaining dumps.

import
  std/[algorithm, os, osproc, streams, strformat, strutils],
  decompbound/rom_pipeline

const
  FramesPerCapture = 3
  MaximumBlockBytes = 1024 * 1024
  StateChunk = "ebSt"
  PngSignature = "\x89PNG\r\n\x1a\n"
  ReportPath = "bin/ppu-palette/corpus.tsv"
  WorkerLifetime = "1800s"
  Components = ["pixels", "PCM", "serialized machine/CPU", "handshake"]

proc stateBearing(path: string): bool =
  ## Validate PNG chunk framing while distinguishing image-only files from states.
  if path.endsWith(".state"): return true
  let data = readFile(path)
  if data.len < PngSignature.len or data[0 ..< PngSignature.len] != PngSignature:
    raise newException(ValueError, "Invalid PNG: " & path)
  var position = PngSignature.len
  while position <= data.len - 12:
    var length = 0
    for offset in 0 ..< 4: length = (length shl 8) or data[position + offset].ord
    if length > data.len - position - 12:
      raise newException(ValueError, "Truncated PNG: " & path)
    if data[position + 4 ..< position + 8] == StateChunk: return true
    position += length + 12

proc readBlock(input: Stream): string =
  ## Read one bounded binary block, failing on truncated worker output.
  let length = parseInt(input.readLine())
  if length < 0 or length > MaximumBlockBytes:
    raise newException(ValueError, "Invalid worker block length")
  result = input.readStr(length)
  if result.len != length: raise newException(IOError, "Truncated worker block")

proc compareBlock(left, right: Stream, context: string) =
  ## Compare complete payload bytes rather than exposed-memory hashes alone.
  if readBlock(left) != readBlock(right):
    raise newException(ValueError, context & " differs")

proc checkReferee() =
  ## Prove that equal bytes pass and same-sized differences or truncation fail.
  compareBlock(newStringStream("3\nabc"), newStringStream("3\nabc"), "synthetic")
  for bad in ["3\nabd", "3\nab", "2\nab"]:
    var rejected = false
    try:
      compareBlock(newStringStream("3\nabc"), newStringStream(bad), "synthetic")
    except ValueError, IOError:
      rejected = true
    doAssert rejected, "The byte-comparison referee accepted a difference"

proc closeWorker(worker: Process) =
  ## Close only this harness's process and fail if its worker exited abnormally.
  worker.inputStream.close()
  let code = worker.waitForExit(5000)
  if code == -1:
    worker.terminate()
    discard worker.waitForExit()
  worker.close()
  if code != 0 and getCurrentException() == nil:
    raise newException(IOError, "Renderer worker failed: " & $code)

proc main() =
  ## Exercise both builds on exactly the same ordered set of local captures.
  checkReferee()
  if paramCount() == 1 and paramStr(1) == "--self-test":
    echo "Renderer comparison referee passed its negative controls."
    return
  if paramCount() < 2:
    raise newException(ValueError, "corpus REFERENCE_WORKER CANDIDATE_WORKER [ROOT ...]")
  # Preserve the command name on installations using multicall coreutils.
  let timeout = findExe("timeout", followSymlinks = false)
  if timeout.len == 0: raise newException(IOError, "The corpus needs the timeout utility")
  createDir(ReportPath.parentDir)
  let
    roots = if paramCount() > 2: commandLineParams()[2 .. ^1] else:
      @["bin/states", "../decompbound_secret", getHomeDir() / "Pictures/Screenshots"]
    rom = absolutePath(resolveGoldBaseromPath())
    reference = startProcess(timeout,
      args = @["--foreground", "--kill-after=5s", WorkerLifetime, absolutePath(paramStr(1)),
        rom, absolutePath(ReportPath.parentDir / "reference-worker.log")], options = {})
    candidate = startProcess(timeout,
      args = @["--foreground", "--kill-after=5s", WorkerLifetime, absolutePath(paramStr(2)),
        rom, absolutePath(ReportPath.parentDir / "candidate-worker.log")], options = {})
  defer: closeWorker(reference)
  defer: closeWorker(candidate)
  let report = open(ReportPath, fmWrite)
  defer: report.close()
  var
    paths: seq[string]
    matched, imageOnly, incompatible: int
  for root in roots:
    if fileExists(root): paths.add(absolutePath(root))
    elif dirExists(root):
      for path in walkDirRec(root):
        if path.endsWith(".png") or path.endsWith(".state"):
          paths.add(absolutePath(path))
  paths.sort()
  if paths.len == 0: raise newException(ValueError, "No captures found")
  for index, path in paths:
    if not stateBearing(path):
      inc imageOnly
      report.writeLine(path & "\tIMAGE_ONLY")
      continue
    for worker in [reference, candidate]:
      worker.inputStream.writeLine(path)
      worker.inputStream.flush()
    let
      leftStatus = reference.outputStream.readLine()
      rightStatus = candidate.outputStream.readLine()
    if leftStatus != rightStatus:
      raise newException(ValueError, "Different restore outcome: " & path)
    if leftStatus.startsWith("INCOMPATIBLE "):
      inc incompatible
      report.writeLine(path & "\t" & leftStatus)
      continue
    if leftStatus != "OK":
      raise newException(IOError, "Unexpected worker status for " & path)
    for frame in 0 ..< FramesPerCapture:
      for component in Components:
        compareBlock(reference.outputStream, candidate.outputStream,
          &"{path}, frame {frame}: {component}")
    inc matched
    report.writeLine(path & "\tMATCH\t" & $FramesPerCapture)
    if matched mod 100 == 0:
      report.flushFile()
      echo &"Renderer corpus {index + 1}/{paths.len}: {matched} matched."
  if matched == 0: raise newException(ValueError, "No compatible captures exercised")
  for worker in [reference, candidate]:
    worker.inputStream.writeLine("")
    worker.inputStream.flush()
  echo &"Renderer corpus passed: {matched} captures x {FramesPerCapture} frames; " &
    &"image-only={imageOnly}, incompatible={incompatible}."

main()
