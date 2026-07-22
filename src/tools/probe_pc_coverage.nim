## PC-coverage probe: the emulator as a ground-truth code oracle.
##
## Static tracing (convert_all) stops at every computed/indirect jump (the
## frontier). But every address the CPU actually FETCHES an instruction from is,
## by definition, real executed code — no jump table needs hand-resolving. This
## probe runs the emulator over boot + a directory of save-states + replays,
## records each ROM instruction-fetch address, and writes the observed entry
## points so convert_all can trace from them and grow byte-exact coverage.
##
## Save-states are game data (never committed); the OUTPUT is a list of code
## addresses (facts about structure, like the frontier list) — safe to commit.
##
## Usage:
##   nim r src/tools/probe_pc_coverage.nim <rom> [--states DIR]... [--replays DIR]
##          [--frames N] [--out FILE]
##
## --states DIR   Load every *.state in DIR, run --frames frames each (repeatable).
## --replays DIR  Replay every *.tas in DIR from its pinned start-state.
## --frames N     Frames per state / boot segment (default 240).
## --out FILE     Write observed SNES entry addresses here (default bin/pc_coverage.txt).

import
  std/[os, sets, algorithm, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, policy, memmap, regions, replay, save_state, snesbus]

proc recordFrame(snes: SnesBus, cpu: var Cpu, image: Image,
                 seen: var HashSet[int]) =
  ## One frame, mirroring policy.stepOneFrame, but recording the ROM file offset
  ## of every instruction the CPU fetches. Only real code lands in `seen`.
  var l = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< policy.InstrPerLine:
      if not (cpu.stopped or cpu.waiting):
        let pcAddr = (cpu.pbr.uint32 shl 16) or cpu.pc.uint32
        let fileOff = snesToFile(pcAddr)
        if fileOff >= 0:
          seen.incl fileOff
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if l < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc l
    if l >= 262:
      snes.initHdma()
      break

proc runSegment(rom: seq[uint8], statePath: string, frames: int,
                seen: var HashSet[int]) =
  ## Boot fresh, optionally load a state, run `frames` frames sampling a few
  ## button presses so menu/confirm paths execute too.
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  if statePath.len > 0 and fileExists(statePath):
    deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  # Cycle through neutral + the face buttons + a d-pad tap so confirm/cancel and
  # movement dispatch paths get exercised, not just idle-loop code.
  const stimulus = [0x0000'u16, 0x0080, 0x8000, 0x0100, 0x0400, 0x0800, 0x0200]
  for f in 0 ..< frames:
    snes.joy1 = stimulus[(f div 20) mod stimulus.len]
    recordFrame(snes, cpu, img, seen)

proc runReplay(rom: seq[uint8], tasPath: string, seen: var HashSet[int]) =
  ## Replay a recorded .tas from its pinned start-state, feeding joy1 from the log.
  let (header, deltas) = parseReplay(tasPath)
  let startRef = header.startStateRef
  # Start-state sits next to the .tas (either an absolute ref or a sibling file).
  var statePath = startRef
  if not fileExists(statePath):
    statePath = tasPath.parentDir / startRef.extractFilename
  if not fileExists(statePath):
    stderr.writeLine &"  skip {tasPath.extractFilename}: start-state not found ({startRef})"
    return
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let table = deltasToTable(deltas)
  let lastFrame = if deltas.len > 0: deltas[^1].frame + 60 else: 300
  var held = 0'u16
  for f in 0 .. lastFrame:
    if table.hasKey(f): held = table[f]
    snes.joy1 = held
    recordFrame(snes, cpu, img, seen)

proc main() =
  var
    romPath = ""
    stateDirs: seq[string]
    replayDirs: seq[string]
    frames = 240
    outPath = "src/decompbound/observed_entries.txt"
    i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    case arg
    of "--": discard
    of "--states": inc i; stateDirs.add paramStr(i)
    of "--replays": inc i; replayDirs.add paramStr(i)
    of "--frames": inc i; frames = parseInt(paramStr(i))
    of "--out": inc i; outPath = paramStr(i)
    else:
      if romPath.len == 0 and not arg.startsWith("--"):
        romPath = arg
      else:
        echo "Unknown arg: ", arg
        quit(1)
    inc i
  if romPath.len == 0:
    echo "Usage: nim r src/tools/probe_pc_coverage.nim <rom> [--states DIR] [--replays DIR] [--frames N] [--out FILE]"
    quit(1)

  let rom = policy.readRomFile(romPath)
  var seen = initHashSet[int]()

  stderr.writeLine "boot segment..."
  runSegment(rom, "", frames, seen)

  for dir in stateDirs:
    if not dirExists(dir): continue
    for path in walkFiles(dir / "*.state"):
      stderr.writeLine &"state {path.extractFilename}..."
      runSegment(rom, path, frames, seen)

  for dir in replayDirs:
    if not dirExists(dir): continue
    for path in walkFiles(dir / "*.tas"):
      stderr.writeLine &"replay {path.extractFilename}..."
      runReplay(rom, path, seen)

  # How much of what we observed is genuinely new (outside implemented regions)?
  var implemented = initHashSet[int]()
  for region in allRegions():
    for off in region.offset ..< region.offset + region.data.len:
      implemented.incl off
  var newOffsets: seq[int]
  for off in seen:
    if off notin implemented:
      newOffsets.add off
  newOffsets.sort()

  # Emit observed entry addresses (SNES) — sorted, one hex per line.
  createDir(outPath.parentDir)
  var body = "# Observed instruction-fetch addresses (SNES) — regenerate via probe_pc_coverage.\n"
  var snesAddrs: seq[int]
  for off in seen: snesAddrs.add fileToSnes(off).int
  snesAddrs.sort()
  for a in snesAddrs:
    body.add &"{a:06X}\n"
  writeFile(outPath, body)

  stderr.writeLine ""
  stderr.writeLine &"observed executed ROM bytes: {seen.len}"
  stderr.writeLine &"  already implemented:       {seen.len - newOffsets.len}"
  stderr.writeLine &"  NEW (outside regions):     {newOffsets.len}"
  stderr.writeLine &"wrote {snesAddrs.len} entry addresses to {outPath}"

when isMainModule:
  main()
