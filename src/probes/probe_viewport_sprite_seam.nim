## Replay a private mono-retro capture segment to diagnose original-frame sprite seams.
## Usage: nim r src/probes/probe_viewport_sprite_seam.nim PRIVATE_SESSION_DIRECTORY.
## Retained while the top-edge seam is open; output stays in ignored bin/.

import
  std/[json, options, os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, cpu_polling, expanded_viewport, frame_step, ppu, replay_run,
    rom_pipeline, save_state, snesbus]

const
  ViewWidth = 336
  ViewHeight = 256
  MismatchedFrameLimit = 5
  PixelPrintLimit = 5
  ProgressInterval = 3000
  OamSprites = 128
  OamLowBytes = OamSprites * 4
  ObjectXWrap = 512
  SmallSizes = [8, 8, 8, 16, 16, 32, 16, 16]
  LargeSizes = [16, 32, 64, 32, 64, 64, 32, 32]
    ## Match the native PPU's current OBSEL interpretation for diagnostic bounds.

proc main() =
  ## Replay a private player segment and compare world actors along the original frame edges.
  if paramCount() != 1:
    raise newException(ValueError, "Supply a private capture directory containing segment_0001.json")
  let
    root = paramStr(1)
    metadata = parseFile(root / "segment_0001.json")
    rom = readGoldBaserom()
    machinePair = newPollingMachine(rom)
    machine = machinePair.machine
    view = newExpandedViewport(rom, ViewWidth, ViewHeight)
    original = newImage(ScreenWidth, ScreenHeight)
  defer:
    view.detachSprites()
    machine.bus.readHook = nil
    machine.bus.writeHook = nil
    machine.apu.spc.readHook = nil
    machine.apu.spc.writeHook = nil
  var
    cpu: Cpu
    events: seq[JsonNode]
    eventIndex, buttons, badFrames: int
    displayedOam: array[544, uint8]
    displayedSelection: int
  deserializeState(cast[seq[uint8]](readFile(root / metadata["checkpoint"].getStr)), machine, cpu)
  for line in lines(root / metadata["inputs"].getStr):
    let event = parseJson(line)
    if event.hasKey("frame"): events.add(event)
  view.attachSprites(machine)
  let
    capture: VisibleFrameHook = proc(snes: SnesBus) =
      ## Freeze the same presentation boundary as the libretro core.
      view.capture(snes)
      displayedOam = snes.oam
      displayedSelection = snes.ppuRegs[1].int
    scanline: ScanlineHook = proc(snes: SnesBus, line: int) =
      ## Retain the existing supported line-effect observations.
      view.captureScanline(snes, line)
  for frame in 0 ..< metadata["frames"].getInt:
    while eventIndex < events.len and events[eventIndex]["frame"].getInt <= frame:
      buttons = events[eventIndex]["buttons"].getInt
      inc eventIndex
    machine.joy1 = 0
    for bit in 0 .. 11:
      if (buttons and (1 shl bit)) != 0:
        machine.joy1 = machine.joy1 or (1'u16 shl (15 - bit))
    stepReplayFrame(machine, cpu, original, polling = machinePair.polling,
      onVisibleFrame = capture, onScanline = scanline)
    if view.presentation != "extended map" or view.spriteStatus != "matched": continue
    let origin = view.worldOrigin
    var
      differences = 0
      firstX = ScreenWidth
      lastX = -1
      firstY = ScreenHeight
      lastY = -1
    for y in 0 ..< ScreenHeight:
      for x in 0 ..< ScreenWidth:
        if x notin [0, ScreenWidth - 1] and y notin [0, ScreenHeight - 1]: continue
        let actor = view.actorPixel(origin.x + x, origin.y + y)
        if actor.isSome and actor.get != original[x, y]:
          if differences < PixelPrintLimit:
            echo &"frame={frame} nativeXY={x},{y} actor={actor.get} native={original[x,y]}"
          inc differences
          firstX = min(firstX, x)
          lastX = max(lastX, x)
          firstY = min(firstY, y)
          lastY = max(lastY, y)
    if differences > 0:
      echo &"  mismatchedEdgePixels={differences} x={firstX}..{lastX} y={firstY}..{lastY}"
      inc badFrames
      if badFrames == 1:
        view.compose(original).writeFile("bin/viewport-seam-first.png")
        for index in 0 ..< OamSprites:
          let
            extra = (displayedOam[OamLowBytes + index div 4].int shr ((index mod 4) * 2)) and 3
            rawX = displayedOam[index * 4].int or ((extra and 1) shl 8)
            x = if rawX >= ObjectXWrap div 2: rawX - ObjectXWrap else: rawX
            size = if (extra and 2) != 0:
                LargeSizes[displayedSelection shr 5]
              else: SmallSizes[displayedSelection shr 5]
            y = displayedOam[index * 4 + 1].int
          if x <= lastX and x + size > firstX and y >= ScreenHeight:
            echo &"  native OAM index={index} x={x} y={y} size={size} yPlusSize={y+size}"
      if badFrames == MismatchedFrameLimit: break
    if frame mod ProgressInterval == 0: echo &"checked {frame} frames"
  echo &"edge mismatch frames={badFrames}"

main()
