## Scratch: WRAM snapshot diffs along a replayed .tas — hunts (a) the real
## "dialogue window open" byte(s) and (b) sticky story flags (talked-to-Pokey).
## Usage: probe_replay_flagdiff <tas> <frameA> <frameB> [frameC...]
## Snapshots full WRAM at each frame; prints byte diffs between consecutive
## snapshots (filtered: skips volatile regions like entity pos arrays, stack,
## OAM shadows — tuned crudely by diff-count threshold per 256-byte page).

import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, replay]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  InstrPerLine = 150
  SamplesPerFrame = 533
  WramLen = 0x20000
  ## Pages with more diffs than this are churn (engine scratch), not flags.
  PageChurnMax = 12

proc readRom(path: string): seq[uint8] =
  ## ROM bytes minus optional copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc stepFrame(snes: SnesBus, c: var Cpu) =
  ## play.nim-faithful frame, no rendering.
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

proc snapshotWram(snes: SnesBus): seq[uint8] =
  ## Copy full 128KB WRAM.
  result = newSeq[uint8](WramLen)
  for i in 0 ..< WramLen:
    result[i] = snes.bus.mem[0x7E0000 + i]

proc diffReport(a, b: seq[uint8], tagA, tagB: string) =
  ## Print per-page-filtered byte diffs between two WRAM snapshots.
  echo &"--- diff {tagA} -> {tagB} ---"
  var page = 0
  var total = 0
  while page < WramLen:
    let hi = min(page + 256, WramLen)
    var idxs: seq[int] = @[]
    for i in page ..< hi:
      if a[i] != b[i]:
        idxs.add i
    if idxs.len > 0 and idxs.len <= PageChurnMax:
      for i in idxs:
        echo &"  $7E{i:05X}: {a[i]:02X} -> {b[i]:02X}"
        inc total
    elif idxs.len > PageChurnMax:
      echo &"  [page $7E{page:05X}: {idxs.len} diffs — churn, skipped]"
    page = hi
  echo &"  ({total} quiet-page byte diffs shown)"

proc main() =
  ## Replay, snapshot at requested frames, diff consecutive pairs.
  var args: seq[string] = @[]
  for i in 1 .. paramCount():
    if paramStr(i) != "--":
      args.add paramStr(i)
  if args.len < 3:
    echo "usage: probe_replay_flagdiff <tas> <frameA> <frameB> [more frames]"
    quit(1)
  let tasPath = args[0]
  var marks: seq[int] = @[]
  for k in 1 ..< args.len:
    marks.add parseInt(args[k])
  let (header, deltas) = parseReplay(tasPath)
  let rom = readRom(RomPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(header.startStateRef)), snes, c)

  var snaps: seq[(int, seq[uint8])] = @[]
  let lastMark = marks[^1]
  for f in 0 .. lastMark:
    snes.joy1 = joyAtFrame(deltas, f)
    stepFrame(snes, c)
    if f in marks:
      snaps.add (f, snapshotWram(snes))
      echo &"snapshot @f={f} pos=(0x{snes.bus.mem[0x7E0BBE].int or (snes.bus.mem[0x7E0BBF].int shl 8):04X},0x{snes.bus.mem[0x7E0BFA].int or (snes.bus.mem[0x7E0BFB].int shl 8):04X})"
  for k in 1 ..< snaps.len:
    diffReport(snaps[k-1][1], snaps[k][1], &"f{snaps[k-1][0]}", &"f{snaps[k][0]}")

when isMainModule:
  main()
