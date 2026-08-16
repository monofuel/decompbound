## Scan a recorded play session (.tas + _start.state) for battle entries:
## replay with the play-faithful stepper and log every $98A5 phase change and
## $4DBA battle-live flip with frame numbers. Optionally dump a .state a given
## number of frames BEFORE the first entry (a HEALTHY pre-entry fixture for
## probe_battle_entry_apu) — all under gitignored bin/ paths.
## Usage: nim r src/probes/probe_replay_battle_scan.nim <seg.tas> [--pre N]
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, replay, save_state, snesbus, policy]

const
  Rom = "bin/Earthbound (U) [!].smc"
  InstrPerLine = 150
  SamplesPerFrame = 533

proc wram(snes: SnesBus, off: int): int =
  ## WRAM byte at 7E:off.
  snes.bus.mem[0x7E0000 + off].int

proc wram16(snes: SnesBus, off: int): int =
  ## WRAM word at 7E:off.
  wram(snes, off) or (wram(snes, off + 1) shl 8)

proc stepFrame(snes: SnesBus, c: var Cpu) =
  ## Play-faithful frame (mirrors replay_seek: HDMA per line, APU topped up).
  var samples = 0
  var l = 0
  while l < 262:
    snes.tickScanline(l)
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for i in 0 ..< InstrPerLine:
      c.step(snes.bus)
      if c.stopped:
        break
    if l < 224:
      snes.runHdma()
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

proc main() =
  let tasPath = paramStr(1)
  var preFrames = 120
  if paramCount() >= 3 and paramStr(2) == "--pre":
    preFrames = parseInt(paramStr(3))
  let (header, deltas) = parseReplay(tasPath)
  let startState = tasPath.replace(".tas", "_start.state")
  if not fileExists(startState):
    echo "MISSING start state: ", startState
    quit(2)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(startState)), snes, c)
  var lastFrame = 0
  for d in deltas:
    if d.frame > lastFrame: lastFrame = d.frame
  echo fmt"{tasPath}: {deltas.len} deltas, last frame {lastFrame}"
  var prevPhase = wram(snes, 0x98A5)
  var prev4dba = wram16(snes, 0x4DBA)
  var firstEntryFrame = -1
  var preSaved = false
  for f in 0 .. lastFrame + 600:
    snes.joy1 = joyAtFrame(deltas, f)
    # Save the pre-entry state preFrames ahead of a known entry on a SECOND
    # pass; single pass: ring-buffer the last state instead — cheap version:
    # save every 60 frames into a rotating slot until entry seen.
    if not preSaved and f mod 60 == 0:
      writeFile("bin/states/llm/replay_pre_ring.state",
        cast[string](serializeState(snes, c)))
    stepFrame(snes, c)
    let phase = wram(snes, 0x98A5)
    let b4dba = wram16(snes, 0x4DBA)
    if phase != prevPhase or b4dba != prev4dba:
      echo fmt"f={f} 98A5 {prevPhase}->{phase} 4DBA {prev4dba:04X}->{b4dba:04X} " &
        fmt"5D7C={wram16(snes, 0x5D7C):04X} mode={(snes.ppuRegs[0x05] and 0x7).int}"
      if phase == 3 and firstEntryFrame < 0:
        firstEntryFrame = f
        preSaved = true
        echo fmt"FIRST ENTRY at f={f}; pre-entry ring state saved earlier at bin/states/llm/replay_pre_ring.state"
      prevPhase = phase
      prev4dba = b4dba
    if c.stopped:
      echo fmt"CPU STOPPED f={f}"
      break
  echo fmt"done. firstEntryFrame={firstEntryFrame}"

when isMainModule:
  main()
