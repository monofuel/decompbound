## Private-corpus renderer worker: binary output goes only to its parent's pipe.

import
  std/[os, strutils],
  pixie,
  decompbound/[cpu, cpu_polling, frame_step, png_state, ppu, replay_run,
    rom_pipeline, save_state, snesbus]

const FramesPerCapture = 3

let protocolOutput = stdout

proc writeBlock(data: pointer, size: int) =
  ## Send a length-prefixed byte block without storing game data on disk.
  protocolOutput.writeLine(size)
  if size > 0 and protocolOutput.writeBuffer(data, size) != size:
    raise newException(IOError, "Short worker output write")

proc capture(path: string, rom: seq[uint8], romHash: uint32) =
  ## Restore one capture, advance the real renderer and stream all comparison state.
  var
    bytes = cast[seq[uint8]](readFile(path))
    current = newPollingMachine(rom)
    cpuState: Cpu
  defer:
    current.polling = nil
    current.machine.bus.readHook = nil
    current.machine.bus.writeHook = nil
    current.machine.apu.spc.readHook = nil
    current.machine.apu.spc.writeHook = nil
  try:
    if path.endsWith(".png"): bytes = extractStateForRom(bytes, romHash)
    deserializeState(bytes, current.machine, cpuState)
  except ValueError as error:
    protocolOutput.writeLine("INCOMPATIBLE " & error.msg.replace('\n', ' '))
    protocolOutput.flushFile()
    return
  protocolOutput.writeLine("OK")
  let image = newImage(ScreenWidth, ScreenHeight)
  var pcm: FramePcm
  for frame in 0 ..< FramesPerCapture:
    image.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(current.machine, cpuState, image, addr pcm, current.polling)
    var state = serializeState(current.machine, cpuState)
    var handshake = current.machine.bus.cpuInApuHandshake
    writeBlock(addr image.data[0], image.data.len * sizeof(ColorRGBX))
    writeBlock(addr pcm[0], sizeof(pcm))
    writeBlock(addr state[0], state.len)
    writeBlock(addr handshake, sizeof(handshake))
  protocolOutput.flushFile()

proc main() =
  ## Keep one worker alive for the corpus to avoid repeated executable startup.
  if paramCount() != 2:
    raise newException(ValueError, "worker ROM DIAGNOSTICS; capture paths arrive on stdin")
  let diagnostics = open(paramStr(2), fmWrite)
  stdout = diagnostics
  defer:
    stdout = protocolOutput
    diagnostics.close()
  let
    rom = readGoldBaserom(paramStr(1))
    romHash = romHashOf(rom)
  var path: string
  while stdin.readLine(path):
    if path.len == 0: break
    capture(path, rom, romHash)

main()
