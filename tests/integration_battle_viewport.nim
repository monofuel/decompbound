import
  std/[algorithm, os, strformat, strutils],
  pixie,
  decompbound/[cpu, ds_companion, expanded_viewport, frame_step, png_state, ppu,
    replay_run, rom_pipeline, save_state, snesbus]

const Wram = 0x7E0000

proc release(machine: SnesBus) =
  ## Release callback cycles between private corpus cases.
  machine.bus.readHook = nil
  machine.bus.writeHook = nil
  machine.apu.spc.readHook = nil
  machine.apu.spc.writeHook = nil

proc checkState(rom, state: seq[uint8], name: string, width, height, frames: int): int =
  ## Verify expanded rendering against an unhooked machine, including original pixels and PCM.
  let
    reference = newSnesBus(rom)
    candidate = newSnesBus(rom)
    view = newExpandedViewport(rom, width, height)
    expected = newImage(ScreenWidth, ScreenHeight)
    original = newImage(ScreenWidth, ScreenHeight)
  defer: reference.release()
  defer: candidate.release()
  var
    referenceCpu, candidateCpu: Cpu
    referencePcm, candidatePcm: FramePcm
  deserializeState(state, reference, referenceCpu)
  deserializeState(state, candidate, candidateCpu)
  let
    visible: VisibleFrameHook = proc(machine: SnesBus) =
      ## Capture presentation only after the original sprite/foreground passes finish.
      view.capture(machine)
    scanline: ScanlineHook = proc(machine: SnesBus, line: int) =
      ## Record actual post-HDMA row state for the expanded background.
      view.captureScanline(machine, line)
  for frame in 0 ..< frames:
    expected.fill(rgbx(0, 0, 0, 255))
    original.fill(rgbx(0, 0, 0, 255))
    stepReplayFrame(reference, referenceCpu, expected, addr referencePcm)
    stepReplayFrame(candidate, candidateCpu, original, addr candidatePcm,
      onVisibleFrame = visible, onScanline = scanline)
    doAssert original.data == expected.data, name & ": original pixels changed"
    doAssert candidatePcm == referencePcm, name & ": PCM changed"
    let before = serializeState(candidate, candidateCpu)
    doAssert before == serializeState(reference, referenceCpu), name & ": machine/CPU changed"
    let
      output = view.compose(original)
      left = (width - ScreenWidth) div 2
      top = (height - ScreenHeight) div 2
    doAssert serializeState(candidate, candidateCpu) == before
    for y in 0 ..< height:
      for x in 0 ..< width:
        doAssert output[x, y].a == 255
        if x >= left and x < left + ScreenWidth and y >= top and y < top + ScreenHeight:
          doAssert output[x, y] == expected[x - left, y - top], name & ": centered image changed"
    if view.presentation == "extended battle": inc result

proc main() =
  ## Sweep private battle captures; explicit paths additionally replay motion across viewport sizes.
  let rom = readGoldBaserom()
  var
    paths: seq[string]
    battles, extended: int
  if paramCount() > 0:
    paths = commandLineParams()
  else:
    for path in walkPattern(getHomeDir() / "Pictures/Screenshots/earthbound_*.png"):
      paths.add(path)
    paths.sort()
  doAssert paths.len > 0, "Supply private state PNGs or populate the local archive."
  for path in paths:
    var state: seq[uint8]
    try:
      state = extractStateForRom(cast[seq[uint8]](readFile(path)), romHashOf(rom))
    except ValueError as error:
      if error.msg != "PNG has no embedded ebSt save-state": raise
      continue
    let machine = newSnesBus(rom)
    defer: machine.release()
    var cpu: Cpu
    deserializeState(state, machine, cpu)
    if not partyBattleVisible(machine.bus.mem.toOpenArray(Wram, Wram + 0x1FFFF),
        (machine.ppuRegs[5] and 7).int):
      continue
    inc battles
    let first = checkState(rom, state, path.extractFilename, 336, 256, 1)
    extended += first
    if paramCount() > 0:
      for (width, height) in [(320, 240), (336, 256), (448, 252), (512, 384), (257, 225)]:
        doAssert checkState(rom, state, path.extractFilename, width, height, 30) > 0,
          path.extractFilename & ": battle never extended"
  echo &"Battle corpus: {extended}/{battles} captures extended; original pixels, PCM and machine/CPU matched."
  doAssert battles > 0 and extended > 0, "No live battle was exercised."

main()
