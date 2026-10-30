## Optional private-capture parity sweep; run explicitly with the user's local archive.

import
  std/[algorithm, os, strformat, strutils],
  pixie,
  decompbound/[cpu, cpu_polling, frame_step, png_state, ppu, replay_run,
    rom_pipeline, save_state, snesbus]

const
  FramesPerCapture = 3
  ProgressInterval = 100
  ChunkOverhead = 12
  StateChunk = [byte('e'), byte('b'), byte('S'), byte('t')]
  OutputPath = "bin/polling/corpus.tsv"

type CaptureKind = enum
  Matched, ImageOnly, Incompatible

proc carriesState(data: seq[uint8]): bool =
  ## Distinguish absent state chunks from malformed state-bearing PNG files.
  if data.len < PngSignature.len or data[0 ..< PngSignature.len] != @PngSignature:
    raise newException(ValueError, "Invalid PNG signature")
  var position = PngSignature.len
  while position <= data.len - ChunkOverhead:
    let length = (data[position].int shl 24) or
      (data[position + 1].int shl 16) or
      (data[position + 2].int shl 8) or data[position + 3].int
    if length > data.len - position - ChunkOverhead:
      raise newException(ValueError, "Truncated PNG chunk")
    if data[position + 4 ..< position + 8] == @StateChunk:
      return true
    position += length + ChunkOverhead

proc release(machine: SnesBus, polling: var CpuPollingContext) =
  ## Release each machine's closure cycles before moving to another capture.
  polling = nil
  if machine != nil:
    machine.bus.readHook = nil
    machine.bus.writeHook = nil
    machine.apu.spc.readHook = nil
    machine.apu.spc.writeHook = nil

proc compareCapture(path: string, rom: seq[uint8], romHash: uint32,
    output: File): CaptureKind =
  ## Compare original replay stepping with batching without exporting any game data.
  var bytes = cast[seq[uint8]](readFile(path))
  if path.endsWith(".png"):
    try:
      if not carriesState(bytes):
        output.writeLine(path & "\tIMAGE_ONLY")
        return ImageOnly
      bytes = extractStateForRom(bytes, romHash)
    except ValueError as error:
      output.writeLine(path & "\tINCOMPATIBLE\t" & error.msg.replace('\n', ' '))
      return Incompatible
  let reference = newSnesBus(rom)
  var
    referenceCpu: Cpu
    noContext: CpuPollingContext
  defer: release(reference, noContext)
  try:
    deserializeState(bytes, reference, referenceCpu)
  except CatchableError as error:
    output.writeLine(path & "\tINCOMPATIBLE\t" & error.msg.replace('\n', ' '))
    return Incompatible
  var
    optimized = newPollingMachine(rom)
    optimizedCpu: Cpu
  defer: release(optimized.machine, optimized.polling)
  deserializeState(bytes, optimized.machine, optimizedCpu)
  let
    referenceImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    optimizedImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var referencePcm, optimizedPcm: FramePcm
  for frame in 0 ..< FramesPerCapture:
    referenceImage.fill(rgbx(0, 0, 0, 255))
    optimizedImage.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(reference, referenceCpu, referenceImage, addr referencePcm)
    stepReplayFrame(optimized.machine, optimizedCpu, optimizedImage,
      addr optimizedPcm, optimized.polling)
    doAssert optimizedCpu == referenceCpu, &"{path}, frame {frame}: CPU differs"
    doAssert optimizedImage.data == referenceImage.data, &"{path}, frame {frame}: pixels differ"
    doAssert optimizedPcm == referencePcm, &"{path}, frame {frame}: PCM differs"
    doAssert serializeState(optimized.machine, optimizedCpu) ==
      serializeState(reference, referenceCpu), &"{path}, frame {frame}: machine state differs"
    doAssert optimized.machine.bus.cpuInApuHandshake == reference.bus.cpuInApuHandshake,
      &"{path}, frame {frame}: handshake marker differs"
  output.writeLine(path & "\tMATCH\t" & $FramesPerCapture)
  Matched

proc main() =
  ## Exercise every local capture and report excluded files explicitly in ignored output.
  let
    roots = if paramCount() > 0: commandLineParams() else:
      @["bin/states", "../decompbound_secret", getHomeDir() / "Pictures/Screenshots"]
    rom = readGoldBaserom()
    romHash = romHashOf(rom)
  createDir(OutputPath.parentDir)
  let output = open(OutputPath, fmWrite)
  defer: output.close()
  var paths: seq[string]
  for root in roots:
    if fileExists(root):
      paths.add(root)
    elif dirExists(root):
      for path in walkDirRec(root):
        if path.endsWith(".png") or path.endsWith(".state"):
          paths.add(path)
  paths.sort()
  doAssert paths.len > 0, "No captures found in the requested roots."
  var counts: array[CaptureKind, int]
  for index, path in paths:
    let kind = compareCapture(path, rom, romHash, output)
    inc counts[kind]
    if (index + 1) mod ProgressInterval == 0:
      output.flushFile()
      echo &"Polling corpus: {index + 1}/{paths.len}; matched={counts[Matched]}, " &
        &"image-only={counts[ImageOnly]}, incompatible={counts[Incompatible]}."
  doAssert counts[Matched] > 0, "No compatible captures were exercised."
  echo &"Polling corpus passed: {counts[Matched]} captures x {FramesPerCapture} frames; " &
    &"image-only={counts[ImageOnly]}, incompatible={counts[Incompatible]}; report={OutputPath}."

main()
