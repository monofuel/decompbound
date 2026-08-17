## Replay the 20260816-183136 TAS at stretch 2/3 and match F12 seats.

import
  std/[os, strformat, strutils, options, tables, times],
  ../decompbound/[cpu, policy, png_state, replay, save_state, snesbus],
  ../tools/touch_grass

const
  RomPath = "bin/Earthbound (U) [!].smc"
  SessionDir = "../decompbound_secret/sessions/20260816-183136"
  StatePath = SessionDir & "/20260816-183136_start.state"
  TasPath = SessionDir & "/20260816-183136.tas"
  F12Dir = SessionDir & "/f12"
  SampleEvery = 200
  MatchRadius = 0x80
  DefaultStretches = [2, 3]

type
  F12Seat = object
    tag: string
    label: string
    fileName: string
    x: int
    y: int
    tg: int
    hitAt: int
    closest: int
    closestAt: int

proc manhattan(ax, ay, bx, by: int): int =
  ## Absolute manhattan distance in world pixels.
  abs(ax - bx) + abs(ay - by)

proc newSeats(): seq[F12Seat] =
  ## Bookmarks the human session called out as route ground truth.
  @[
    F12Seat(tag: "183312", label: "door",
      fileName: "earthbound_20260816-183312.png",
      hitAt: -1, closest: high(int), closestAt: -1),
    F12Seat(tag: "183333", label: "bedroom",
      fileName: "earthbound_20260816-183333.png",
      hitAt: -1, closest: high(int), closestAt: -1),
    F12Seat(tag: "184046", label: "crater",
      fileName: "earthbound_20260816-184046.png",
      hitAt: -1, closest: high(int), closestAt: -1),
    F12Seat(tag: "184619", label: "downtown",
      fileName: "earthbound_20260816-184619.png",
      hitAt: -1, closest: high(int), closestAt: -1),
    F12Seat(tag: "185012", label: "arcade",
      fileName: "earthbound_20260816-185012.png",
      hitAt: -1, closest: high(int), closestAt: -1),
  ]

proc extractSeats(rom: seq[uint8]): seq[F12Seat] =
  ## Pull player pos out of each F12 ebSt payload.
  result = newSeats()
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  for i in 0 ..< result.len:
    let path = F12Dir / result[i].fileName
    if not fileExists(path):
      raise newException(IOError, "missing F12 " & path)
    let png = cast[seq[uint8]](readFile(path))
    let st = extractState(png)
    if st.isNone:
      raise newException(IOError, "no ebSt in " & path)
    deserializeState(st.get, snes, c)
    let (px, py) = replay.playerPos(snes)
    result[i].x = px.int
    result[i].y = py.int
    result[i].tg = touchGrassPercent(snes)
    echo &"F12 {result[i].tag} {result[i].label} pos=({px:04X},{py:04X}) " &
      &"tg={result[i].tg}"

proc resetHits(seats: seq[F12Seat]): seq[F12Seat] =
  ## Copy extracted seats and clear per-stretch hit bookkeeping.
  result = seats
  for i in 0 ..< result.len:
    result[i].hitAt = -1
    result[i].closest = high(int)
    result[i].closestAt = -1

proc notePos(seats: var seq[F12Seat], stretch, tf, px, py, tg: int) =
  ## Record first manhattan<=0x80 hit and running closest approach.
  for i in 0 ..< seats.len:
    let d = manhattan(px, py, seats[i].x, seats[i].y)
    if d < seats[i].closest:
      seats[i].closest = d
      seats[i].closestAt = tf
    if seats[i].hitAt < 0 and d <= MatchRadius:
      seats[i].hitAt = tf
      echo &"HIT s{stretch} {seats[i].tag} {seats[i].label} tas={tf} " &
        &"pos=({px:04X},{py:04X}) dist=0x{d:X} tg={tg}"
      stdout.flushFile

proc runStretch(stretch: int, rom: seq[uint8], lastFrame: int,
    sched: Table[int, uint16], extracted: seq[F12Seat]): seq[F12Seat] =
  ## Hold each TAS delta for `stretch` emu frames and sample the trail.
  result = resetHits(extracted)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(StatePath)), snes, c)
  var joy: uint16 = 0
  var leftTitle = -1
  let t0 = epochTime()
  echo &"=== stretch {stretch} tas=0..{lastFrame} ==="
  stdout.flushFile
  for tf in 0 .. lastFrame:
    if tf in sched:
      joy = sched[tf]
    for s in 1 .. stretch:
      snes.joy1 = joy
      policy.stepOneFrame(snes, c, nil, render = false)
    let (px, py) = replay.playerPos(snes)
    let tg = touchGrassPercent(snes)
    if leftTitle < 0 and (px != 0 or py != 0 or tg > 0):
      leftTitle = tf
      echo &"  stretch={stretch} LEFT title at tas={tf} pos=({px:04X},{py:04X}) " &
        &"tg={tg}"
      stdout.flushFile
    notePos(result, stretch, tf, px.int, py.int, tg)
    if tf mod SampleEvery == 0:
      let elapsed = epochTime() - t0
      echo &"s{stretch} tas={tf} pos=({px:04X},{py:04X}) tg={tg} t={elapsed:.1f}s"
      stdout.flushFile
    if c.stopped:
      echo &"s{stretch} CPU stopped at tas={tf}"
      break
  let (px, py) = replay.playerPos(snes)
  let elapsed = epochTime() - t0
  echo &"stretch={stretch} end tas={lastFrame} pos=({px:04X},{py:04X}) " &
    &"tg={touchGrassPercent(snes)} leftTitle={leftTitle} t={elapsed:.1f}s"
  for s in result:
    if s.hitAt >= 0:
      echo &"  {s.tag} {s.label} HIT tas={s.hitAt} closest=0x{s.closest:X}"
    else:
      echo &"  {s.tag} {s.label} MISS closest=0x{s.closest:X} at tas={s.closestAt}"
  stdout.flushFile

proc cell(seat: F12Seat): string =
  ## Table cell: first-hit TAS frame or MISS.
  if seat.hitAt >= 0:
    $seat.hitAt
  else:
    "MISS"

proc printTable(byStretch: seq[(int, seq[F12Seat])]) =
  ## Stretch x F12 first-hit table.
  if byStretch.len == 0:
    return
  let seats = byStretch[0][1]
  var header = "stretch"
  for s in seats:
    header.add &"\t{s.tag}"
  echo header
  for (st, row) in byStretch:
    var line = $st
    for s in row:
      line.add "\t" & cell(s)
    echo line
  echo "closest (MISS rows):"
  for (st, row) in byStretch:
    for s in row:
      if s.hitAt < 0:
        echo &"  s{st} {s.tag} {s.label} closest=0x{s.closest:X} at tas={s.closestAt}"

proc recommend(byStretch: seq[(int, seq[F12Seat])]): int =
  ## Pick the stretch that hits the most seats, then the latest seat earliest.
  var bestSt = byStretch[0][0]
  var bestHits = -1
  var bestLast = high(int)
  for (st, row) in byStretch:
    var hits = 0
    var lastHit = -1
    for s in row:
      if s.hitAt >= 0:
        inc hits
        lastHit = max(lastHit, s.hitAt)
    let lastKey = if hits == 0: high(int) else: lastHit
    if hits > bestHits or (hits == bestHits and lastKey < bestLast):
      bestHits = hits
      bestLast = lastKey
      bestSt = st
  bestSt

proc parseStretches(): seq[int] =
  ## Optional CLI stretch list; default 2 then 3.
  result = @[]
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a == "--":
      continue
    result.add parseInt(a)
  if result.len == 0:
    for s in DefaultStretches:
      result.add s

proc main() =
  ## Extract F12 seats, replay each stretch, print the hit table.
  if not fileExists(RomPath):
    echo "no ROM at ", RomPath
    quit(1)
  if not fileExists(StatePath):
    echo "no start state at ", StatePath
    quit(1)
  if not fileExists(TasPath):
    echo "no TAS at ", TasPath
    quit(1)
  let rom = policy.readRomFile(RomPath)
  let extracted = extractSeats(rom)
  echo "expected door=(0A68,0150) bedroom=(1FB8,0452) crater=(081B,0079) " &
    "downtown=(0648,048D) arcade=(1E8F,02B8)"
  let (_, deltas) = parseReplay(TasPath)
  if deltas.len == 0:
    echo "empty TAS"
    quit(1)
  let lastFrame = deltas[^1].frame
  let sched = deltasToTable(deltas)
  echo &"TAS deltas={deltas.len} lastFrame={lastFrame} radius=0x{MatchRadius:X} " &
    &"sampleEvery={SampleEvery}"
  let stretches = parseStretches()
  var byStretch: seq[(int, seq[F12Seat])] = @[]
  for st in stretches:
    byStretch.add (st, runStretch(st, rom, lastFrame, sched, extracted))
  echo ""
  echo "=== TABLE stretch x F12 -> tasFrame ==="
  printTable(byStretch)
  let rec = recommend(byStretch)
  echo &"RECOMMEND stretch={rec} for the full movie"
  stdout.flushFile

when isMainModule:
  main()
