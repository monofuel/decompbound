## Headless TAS replay tool for decompbound.
## Loads a pinned start save-state (slot number or .state path), then feeds
## joy1 strictly from the input log (never live input or gamepads).
## Uses exact same frame step (InstrPerLine=150, NMI@224) as play/policy for
## deterministic reproduction of recorded sessions.
##
## Usage:
##   nim r src/tools/replay.nim <rom> <start-state> <input-log.tas> [--png-every N] [--frames N]
##
## <start-state> : integer slot (e.g. 1 -> bin/states/slot1.state) or path to .state
## --png-every N : write frame PNG every N frames into bin/replay_frames/
## --frames N    : stop after N frames (default 300)
##
## Always reports final player world pos ($0B8E/$0BCA) and a WRAM hash.
## Deterministic: same log + start-state must yield identical final pos/hash on re-runs.

import
  std/[os, strformat, strutils, tables, options],
  pixie,
  ../decompbound/[cpu, ppu, policy, png_state, replay, save_state, snesbus]

proc main() =
  ## Parse args, load ROM + start state, parse log, run feeding joy1 from deltas,
  ## optional periodic PNGs, final pos + wram hash report.
  # Skip leading -- separator from `nim c -r`.
  var argBase = 1
  if paramCount() >= 1 and paramStr(1) == "--":
    argBase = 2

  if paramCount() < argBase + 2:
    echo "Usage: nim r src/tools/replay.nim <rom> <start-state> <input-log.tas> [--png-every N] [--frames N]"
    quit(1)

  let romPath = paramStr(argBase)
  let startArg = paramStr(argBase + 1)
  let logPath = paramStr(argBase + 2)

  var pngEvery = 0
  var maxFrames = 300
  var i = argBase + 3
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--png-every" and i < paramCount():
      inc i
      pngEvery = parseInt(paramStr(i))
    elif arg.startsWith("--png-every="):
      pngEvery = parseInt(arg[12 .. ^1])
    elif arg == "--frames" and i < paramCount():
      inc i
      maxFrames = parseInt(paramStr(i))
    elif arg.startsWith("--frames="):
      maxFrames = parseInt(arg[9 .. ^1])
    elif arg == "--":
      discard
    else:
      echo "Unknown arg: ", arg
      quit(1)
    inc i

  let rom = policy.readRomFile(romPath)
  let romHash = romHashOf(rom)
  echo &"ROM: {romPath}  hash=0x{romHash:08X}"
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()

  # Resolve start-state: number => slot load; else => file path + deserialize
  var startRefForLog = startArg
  let slotTry = try: some(parseInt(startArg)) except: none(int)
  if slotTry.isSome:
    let slot = slotTry.get
    echo &"Loading start state from slot {slot} (bin/states/slot{slot}.state)"
    loadState(snes, cpu, slot)
    startRefForLog = &"slot:{slot}"
  else:
    if not fileExists(startArg):
      echo &"ERROR: start-state path not found: {startArg}"
      quit(1)
    echo &"Loading start state from file: {startArg}"
    let data = cast[seq[byte]](readFile(startArg))
    deserializeState(data, snes, cpu)
    startRefForLog = startArg

  # Parse the input log (deltas only on change)
  let (rheader, deltas) = replay.parseReplay(logPath)
  echo &"Loaded replay log: {logPath}  magic={rheader.magic} romHashInLog=0x{rheader.romHash:08X} startRef={rheader.startStateRef}  deltas={deltas.len}"
  if rheader.romHash != 0 and rheader.romHash != romHash:
    echo &"WARNING: log ROM hash 0x{rheader.romHash:08X} != current 0x{romHash:08X} (replay may be for different ROM)"

  # Build joy1 schedule from deltas (frame -> joy1 to set at start of that frame)
  let joySchedule = replay.deltasToTable(deltas)
  echo &"Replay schedule has {joySchedule.len} joy1 changes"
  let (initX, initY) = replay.playerPos(snes)
  echo &"initial player pos (from start state): x=0x{initX:04x} y=0x{initY:04x}"

  if pngEvery > 0:
    createDir("bin/replay_frames")
    echo &"PNG dumps every {pngEvery} frames -> bin/replay_frames/"

  var frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  # Initial clear (will be filled on first step)
  frameImage.fill(rgbx(0, 0, 0, 255))

  var currentJoy1: uint16 = 0
  var replayFrame = 0
  # Use table for O(1) lookup on frame -> joy1.

  echo "Starting headless replay..."
  while replayFrame < maxFrames and not cpu.stopped:
    # Apply any joy1 change scheduled for *this* frame (before stepping it)
    if replayFrame in joySchedule:
      currentJoy1 = joySchedule[replayFrame]
    # TEMP probe: force Down after initial to see if pos moves from game_start
    snes.joy1 = currentJoy1

    # Exact one frame using the canonical stepper (matches play + llm policy runs)
    policy.stepOneFrame(snes, cpu, frameImage)
    inc replayFrame

    if pngEvery > 0 and (replayFrame mod pngEvery == 0):
      let p = &"bin/replay_frames/frame_{replayFrame:04d}.png"
      frameImage.writeFile(p)
      let (px, py) = replay.playerPos(snes)
      echo &"  frame {replayFrame}: wrote {p}  player=({px},{py}) joy1=0x{currentJoy1:04x}"

    if cpu.stopped:
      echo "CPU stopped during replay"
      break

  # Final report (the proof data)
  let (finalX, finalY) = replay.playerPos(snes)
  let finalWramHash = replay.wramHash(snes)
  echo ""
  echo "=== REPLAY COMPLETE ==="
  echo &"frames run: {replayFrame}"
  echo &"final player pos: x=0x{finalX:04x} y=0x{finalY:04x}  ($0B8E/$0BCA)"
  echo &"wram_hash=0x{finalWramHash:08x}"
  echo &"final joy1=0x{snes.joy1:04x}"
  echo &"start_state used: {startArg}"
  echo &"log: {logPath}"

when isMainModule:
  main()
