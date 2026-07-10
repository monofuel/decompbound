## Seek into a recorded play session: turn any (replay segment, frame) into a
## full save-state moment. With always-on input recording (play.nim), this
## makes EVERY moment of EVERY session reconstructible after the fact:
##   .tas (sparse joy1 deltas) + its _start.state + deterministic replay
##   = the exact machine state at any frame N.
## Outputs ebSt PNGs (drag-droppable onto make play, F12-compatible) and/or raw
## .state blobs — always under gitignored bin/ paths (copyright hygiene).
##
## Usage:
##   nim r src/tools/replay_seek.nim <segment.tas> --frame N [--out bin/x.png]
##   nim r src/tools/replay_seek.nim <segment.tas> --every M   # moment map
##   nim r src/tools/replay_seek.nim <segment.tas> --list      # info only
##
## Stepping mirrors play.nim at normal speed (262 lines x 150 instr, NMI@224,
## HDMA per visible line, 2 APU ticks/line + top-up to 533 samples). Sessions
## recorded during fast-forward tick 524/frame live and may drift slightly.
## The embedded state is EXACTLY frame N; the thumbnail pixels are the next
## frame's render (rendering has no state side effects).

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, png_state, replay, save_state, snesbus]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  InstrPerLine = 150       ## play.nim frame budget (see its tuning comment).
  SamplesPerFrame = 533    ## 32000 div 60; play tops up per frame at normal speed.
  OutDirBase = "bin/replay_moments"

proc readRom(path: string): seq[uint8] =
  ## ROM bytes, stripping an optional 512-byte copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc stepFrame(snes: SnesBus, c: var Cpu, image: Image, render: bool) =
  ## One play.nim-faithful frame: render only when asked (no state effects).
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if render and not forceBlank:
    image.fill(ppu.bgr555ToColor(snes.cgram[0]))
  var samples = 0
  var l = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< InstrPerLine:
      c.step(snes.bus)
      if c.stopped:
        break
    if l < 224:
      snes.runHdma()
      if render and (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      discard snes.tickApu()
      inc samples
    inc l
    if l >= 262:
      snes.initHdma()
      break
  while samples < SamplesPerFrame:
    discard snes.tickApu()
    inc samples
  if render:
    ppu.renderSprites(snes, image)
    ppu.overlayForegroundBg(snes, image)

proc emitMoment(snes: SnesBus, c: var Cpu, rom: seq[uint8], outPath: string) =
  ## Serialize the CURRENT state, render one thumbnail frame, write ebSt PNG,
  ## then RESTORE the serialized state so the replay timeline is unperturbed.
  let stateBytes = serializeState(snes, c)
  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  stepFrame(snes, c, image, render = true)
  let png = image.encodeImage(PngFormat)
  let bundled = embedState(cast[seq[uint8]](png), cast[seq[uint8]](stateBytes),
    romHashOf(rom))
  createDir(parentDir(outPath))
  writeFile(outPath, cast[string](bundled))
  deserializeState(stateBytes, snes, c)

proc main() =
  ## Parse args, replay the segment, emit the requested moment(s).
  var
    tasPath = ""
    frameN = -1
    everyN = 0
    outPath = ""
    listOnly = false
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--":
      discard
    elif a == "--frame" and i < paramCount():
      inc i
      frameN = parseInt(paramStr(i))
    elif a.startsWith("--frame="):
      frameN = parseInt(a[8..^1])
    elif a == "--every" and i < paramCount():
      inc i
      everyN = parseInt(paramStr(i))
    elif a.startsWith("--every="):
      everyN = parseInt(a[8..^1])
    elif a == "--out" and i < paramCount():
      inc i
      outPath = paramStr(i)
    elif a.startsWith("--out="):
      outPath = a[6..^1]
    elif a == "--list":
      listOnly = true
    elif tasPath.len == 0:
      tasPath = a
    else:
      echo "unknown arg: ", a
      quit(1)
    inc i
  if tasPath.len == 0:
    echo "usage: replay_seek <segment.tas> [--frame N] [--every M] [--out PATH] [--list]"
    quit(1)

  let (header, deltas) = parseReplay(tasPath)
  let lastFrame = if deltas.len > 0: deltas[^1].frame else: 0
  echo &"segment: {tasPath}"
  echo &"  start state: {header.startStateRef}  deltas: {deltas.len}  last input frame: {lastFrame}"
  if listOnly:
    return
  if not fileExists(header.startStateRef):
    echo "start state missing: ", header.startStateRef
    quit(1)

  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(header.startStateRef)), snes, c)
  if header.romHash != romHashOf(rom):
    echo &"WARN: rom hash mismatch (tas 0x{header.romHash:08X} vs 0x{romHashOf(rom):08X})"

  let target = if frameN >= 0: frameN else: lastFrame
  let segName = tasPath.extractFilename().changeFileExt("")
  let image = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var emitted = 0
  for f in 0 .. target:
    snes.joy1 = joyAtFrame(deltas, f)
    if everyN > 0 and f mod everyN == 0:
      let (px, py) = replay.playerPos(snes)
      emitMoment(snes, c, rom, OutDirBase / segName / &"f{f:06}_x{px:04X}_y{py:04X}.png")
      inc emitted
    stepFrame(snes, c, image, render = false)
  if everyN > 0:
    echo &"wrote {emitted} moments under {OutDirBase}/{segName}/"
  else:
    let dest = if outPath.len > 0: outPath
      else: OutDirBase / segName / &"f{target:06}.png"
    emitMoment(snes, c, rom, dest)
    let (px, py) = replay.playerPos(snes)
    echo &"moment @frame {target}: player=(0x{px:04X},0x{py:04X}) -> {dest} (drag onto make play)"

when isMainModule:
  main()
