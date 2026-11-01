import
  std/[os, strutils],
  pixie,
  ../../src/decompbound/[cpu, cpu_polling, expanded_viewport, frame_step,
    png_state, ppu, replay_run, rom_pipeline, save_state, snesbus]

let protocolOutput = stdout

proc writeBlock(data: pointer, size: int) =
  ## Stream complete comparison bytes privately through the existing corpus protocol.
  protocolOutput.writeLine(size)
  if size > 0 and protocolOutput.writeBuffer(data, size) != size:
    raise newException(IOError, "Short viewport comparison write")

proc capture(path: string, rom: seq[uint8], romHash: uint32) =
  ## Compare expanded pixels and full machine state across two independently built renderers.
  let
    width = parseInt(getEnv("VIEWPORT_PARITY_WIDTH", "336"))
    height = parseInt(getEnv("VIEWPORT_PARITY_HEIGHT", "256"))
    frames = parseInt(getEnv("PPU_CORPUS_FRAMES", "3"))
    current = newPollingMachine(rom)
    image = newImage(ScreenWidth, ScreenHeight)
    view = newExpandedViewport(rom, width, height)
  if frames notin 1..3600:
    raise newException(ValueError, "PPU_CORPUS_FRAMES must be inside 1..3600")
  var
    bytes = cast[seq[uint8]](readFile(path))
    cpuState: Cpu
  defer:
    view.detachSprites()
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
  view.attachSprites(current.machine)
  var pcm: FramePcm
  for frame in 0..<frames:
    image.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(current.machine, cpuState, image, addr pcm, current.polling,
      onVisibleFrame = proc(snes: SnesBus) = view.capture(snes),
      onScanline = proc(snes: SnesBus, line: int) = view.captureScanline(snes, line))
    let output = view.compose(image)
    var
      state = serializeState(current.machine, cpuState)
      handshake = current.machine.bus.cpuInApuHandshake
    writeBlock(addr output.data[0], output.data.len * sizeof(ColorRGBX))
    writeBlock(addr pcm[0], sizeof(pcm))
    writeBlock(addr state[0], state.len)
    writeBlock(addr handshake, sizeof(handshake))
  protocolOutput.flushFile()

proc main() =
  ## Serve private capture paths using a caller-selected geometry and frame count.
  if paramCount() != 2:
    raise newException(ValueError, "viewport_worker ROM DIAGNOSTICS; paths arrive on stdin")
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
