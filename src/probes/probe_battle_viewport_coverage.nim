## Diagnose missing horizontal battle margins using private state captures.
## Usage: nim r src/probes/probe_battle_viewport_coverage.nim [PRIVATE_PNG ...].
## Without arguments, inspect mode-0 archive candidates; explicit paths may use any mode.
## Retained while horizontal battle coverage is incomplete.
## TODO: Share the named PPU/WRAM offsets with the renderer if this diagnostic graduates.
import
  std/[algorithm, importutils, os, strformat, tables],
  pixie,
  ../decompbound/[battle_viewport, cpu, cpu_polling, expanded_viewport,
    frame_step, png_state, ppu, replay_run, rom_pipeline, save_state, snesbus]

privateAccess(ExpandedViewport)
privateAccess(BattleViewport)

proc main() =
  ## Count visible side extension independently of the renderer's selected-path flag.
  let
    rom = readGoldBaserom()
    view = newExpandedViewport(rom, 336, 256)
    image = newImage(ScreenWidth, ScreenHeight)
  var
    paths: seq[string]
    results = initCountTable[string]()
  if paramCount() > 0:
    paths = commandLineParams()
  else:
    for path in walkFiles(getHomeDir() / "Pictures/Screenshots/earthbound_*.png"): paths.add(path)
    paths.sort()
  for pathIndex in 0 ..< paths.len:
    let path = paths[pathIndex]
    var state: seq[uint8]
    try:
      state = extractStateForRom(cast[seq[uint8]](readFile(path)), romHashOf(rom))
    except ValueError as error:
      if error.msg != "PNG has no embedded ebSt save-state": raise
      continue
    let
      pair = newPollingMachine(rom)
      snes = pair.machine
    var cpu: Cpu
    deserializeState(state, snes, cpu)
    let mode = (snes.ppuRegs[5] and 7).int
    if mode != 0 and paramCount() == 0:
      snes.bus.readHook = nil
      snes.bus.writeHook = nil
      snes.apu.spc.readHook = nil
      snes.apu.spc.writeHook = nil
      continue
    view.attachSprites(snes)
    var
      rejection = ""
      modeRows: array[8, int]
    let
      scanline: ScanlineHook = proc(machine: SnesBus, line: int) =
        ## Record source eligibility without modifying its decision.
        view.captureScanline(machine, line)
        if line == 0:
          rejection = ""
          modeRows = default(array[8, int])
        inc modeRows[(machine.ppuRegs[5] and 7).int]
        if not view.battle.valid and rejection.len == 0:
          rejection = &"row={line} mode={machine.ppuRegs[5]:02X} mosaic={machine.ppuRegs[6]:02X} " &
            &"display={machine.ppuRegs[0]:02X} party={machine.bus.read16(0x7E4DC8):04X}"
      capture: VisibleFrameHook = proc(machine: SnesBus) =
        ## Capture the exact presentation frame preceding NMI.
        view.capture(machine)
    for frame in 0 ..< 3:
      stepReplayFrame(snes, cpu, image, polling = pair.polling,
        onVisibleFrame = capture, onScanline = scanline)
    let output = view.compose(image)
    var sidePixels = 0
    for y in 16 ..< 240:
      for x in 0 ..< 336:
        if x in 40 ..< 296: continue
        let pixel = output[x, y]
        if pixel.r != 0 or pixel.g != 0 or pixel.b != 0: inc sidePixels
    let category = if view.presentation == "extended battle":
        (if sidePixels == 0: "selected-but-black-sides" else: "visible-side-extension")
      else: "not-extended-battle"
    results.inc(category)
    if category != "visible-side-extension":
      echo &"{path.extractFilename} {category} ready={view.battle.ready} valid={view.battle.valid} " &
        &"lines={view.battle.lines} bg={view.battle.hasBackground} sides={sidePixels} " &
        &"main={snes.ppuRegs[0x2C]:02X} sub={snes.ppuRegs[0x2D]:02X} " &
        &"wsel={snes.ppuRegs[0x25]:02X} w34={snes.ppuRegs[0x24]:02X} " &
        &"wmask={snes.ppuRegs[0x2E]:02X}/{snes.ppuRegs[0x2F]:02X} " &
        &"bounds={snes.ppuRegs[0x26]:02X}..{snes.ppuRegs[0x27]:02X} " &
        &"cgwsel={snes.ppuRegs[0x30]:02X} " &
        &"status={view.presentation} modes={modeRows} {rejection}"
    view.detachSprites()
    snes.bus.readHook = nil
    snes.bus.writeHook = nil
    snes.apu.spc.readHook = nil
    snes.apu.spc.writeHook = nil
  echo results

main()
