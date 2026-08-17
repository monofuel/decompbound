## Headless TAS report: replay a .tas + start state, sample WRAM, write markdown.
## Output is game text — only under bin/reports/ (gitignored). Never commit it.

import
  std/[algorithm, options, os, strformat, strutils],
  ../decompbound/[
    build_info,
    cpu,
    party_wram,
    png_state,
    policy,
    replay,
    replay_run,
    run_report,
    save_state,
    snesbus,
  ],
  ./[story_percents, touch_grass]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  MoneyWram = 0x9831

proc readRom(path: string): seq[uint8] =
  ## ROM bytes, stripping an optional 512-byte copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc lastDeltaFrame(deltas: seq[ReplayDelta]): int =
  ## Last recorded input frame, or 0.
  if deltas.len == 0:
    return 0
  result = deltas[^1].frame

proc pickSessionPair(sessionDir: string): tuple[tas, state: string] =
  ## Longest .tas in the session dir plus its matching _start.state.
  if not dirExists(sessionDir):
    echo "ERROR: session dir not found: ", sessionDir
    quit(1)
  var best = ""
  var bestLen = -1
  for kind, path in walkDir(sessionDir):
    if kind != pcFile:
      continue
    if not path.endsWith(".tas"):
      continue
    let n = getFileSize(path).int
    if n > bestLen:
      bestLen = n
      best = path
  if best.len == 0:
    echo "ERROR: no .tas in ", sessionDir
    quit(1)
  let stem = best[0 ..< best.len - 4]
  let startP = stem & "_start.state"
  if not fileExists(startP):
    echo "ERROR: missing start state: ", startP
    quit(1)
  (best, startP)

proc sampleSpine(snes: SnesBus): seq[(string, int)] =
  ## Checkpoint spine + bitpop, same ids as checkpointSpineLine.
  @[
    ("tg", touchGrassPercent(snes)),
    ("pokey", pokeyPercent(snes)),
    ("pokey_knock", pokeyKnockPercent(snes)),
    ("buzzbuzz", buzzBuzzPercent(snes)),
    ("sunrise", sunrisePercent(snes)),
    ("frank", frankPercent(snes)),
    ("giant_step", giantStepPercent(snes)),
    ("captain_strong", captainStrongPercent(snes)),
    ("peaceful_rest", peacefulRestPercent(snes)),
    ("paula_rescue", paulaRescuePercent(snes)),
    ("lilliput_steps", lilliputStepsPercent(snes)),
    ("winters", wintersPercent(snes)),
    ("belch", belchPercent(snes)),
    ("fourside", foursidePercent(snes)),
    ("monotoli", monotoliPercent(snes)),
    ("summers", summersPercent(snes)),
    ("deep_darkness", deepDarknessPercent(snes)),
    ("stonehenge", stonehengePercent(snes)),
    ("magicant", magicantPercent(snes)),
    ("giygas", giygasPercent(snes)),
    ("bitpop", eventFlagBitPop(snes)),
  ]

proc sampleParty(snes: SnesBus): seq[PartySnap] =
  ## Live WRAM party as report snaps. Item labels use ROM names when present.
  let vitals = readPartyVitalsFromWram(snes)
  for m in vitals.members:
    var items: seq[string] = @[]
    for it in m.inventory:
      if it.name.len > 0:
        items.add it.name
      else:
        items.add $it.id
    result.add PartySnap(
      role: m.role,
      name: m.name,
      level: m.level,
      exp: m.exp,
      hp: m.hp,
      hpMax: m.hpMax,
      inParty: m.inParty,
      items: items,
    )

proc sampleFrame(snes: SnesBus, frame: int): FrameSample =
  ## One WRAM sample. Cheap reads only — no render.
  let (px, py) = replay.playerPos(snes)
  result.frame = frame
  result.dialogue = getDialogueBlock(snes)
  if not usableDialogue(result.dialogue):
    result.dialogue = getRecentDialogue(snes)
  if not usableDialogue(result.dialogue):
    result.dialogue = ""
  result.inBattle = isInBattle(snes)
  result.battleText =
    if result.inBattle: cleanBattleText(getBattleText(snes)) else: ""
  result.room = reportRoomLabel(px.int, py.int, result.inBattle)
  result.money = touch_grass.readU16(snes, MoneyWram).int
  result.posX = px.int
  result.posY = py.int
  result.spine = sampleSpine(snes)
  result.members = sampleParty(snes)

proc loadBookmark(rom: seq[uint8], pngPath: string): Bookmark =
  ## Deserialize ebSt from an F12 and sample WRAM. Empty name if no chunk.
  result.name = pngPath.extractFilename
  let pngBytes = cast[seq[uint8]](readFile(pngPath))
  let stOpt = extractState(pngBytes)
  if stOpt.isNone:
    result.sample.room = "(no ebSt)"
    return
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](stOpt.get), snes, cpu)
  result.sample = sampleFrame(snes, 0)

proc collectBookmarks(rom: seq[uint8], sessionDir: string): seq[Bookmark] =
  ## Sample every PNG under session/f12/, name order.
  let f12 = sessionDir / "f12"
  if not dirExists(f12):
    return
  var paths: seq[string] = @[]
  for kind, path in walkDir(f12):
    if kind == pcFile and path.endsWith(".png"):
      paths.add path
  paths.sort()
  for p in paths:
    echo "  bookmark ", p.extractFilename
    result.add loadBookmark(rom, p)

proc defaultOutPath(tasPath: string): string =
  ## bin/reports/<tas-stem>.md
  let stem = tasPath.extractFilename.changeFileExt("")
  ReportOutDir / (stem & ".md")

proc parseArgs(): tuple[rom, state, tas, outPath: string, frames: int, session: string,
    bookmarksOnly: bool, stretch: int] =
  ## CLI args. Session mode fills tas/state from the longest pair.
  result.rom = ""
  result.state = ""
  result.tas = ""
  result.outPath = ""
  result.frames = -1
  result.session = ""
  result.bookmarksOnly = false
  result.stretch = 1
  var i = 1
  if paramCount() >= 1 and paramStr(1) == "--":
    i = 2
  var pos: seq[string] = @[]
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--session" and i < paramCount():
      inc i
      result.session = paramStr(i)
    elif arg.startsWith("--session="):
      result.session = arg[10 .. ^1]
    elif arg == "--out" and i < paramCount():
      inc i
      result.outPath = paramStr(i)
    elif arg.startsWith("--out="):
      result.outPath = arg[6 .. ^1]
    elif arg == "--frames" and i < paramCount():
      inc i
      result.frames = parseInt(paramStr(i))
    elif arg.startsWith("--frames="):
      result.frames = parseInt(arg[9 .. ^1])
    elif arg == "--rom" and i < paramCount():
      inc i
      result.rom = paramStr(i)
    elif arg.startsWith("--rom="):
      result.rom = arg[6 .. ^1]
    elif arg == "--bookmarks-only":
      result.bookmarksOnly = true
    elif arg == "--legacy-stretch" and i < paramCount():
      inc i
      result.stretch = parseInt(paramStr(i))
    elif arg.startsWith("--legacy-stretch="):
      result.stretch = parseInt(arg[17 .. ^1])
    elif arg == "--stretch" and i < paramCount():
      inc i
      result.stretch = parseInt(paramStr(i))
    elif arg.startsWith("--stretch="):
      result.stretch = parseInt(arg[10 .. ^1])
    elif arg.startsWith("-"):
      echo "Unknown arg: ", arg
      quit(1)
    else:
      pos.add arg
    inc i
  if result.session.len > 0:
    let pair = pickSessionPair(result.session)
    result.tas = pair.tas
    result.state = pair.state
    if result.rom.len == 0:
      result.rom = DefaultRom
  else:
    if pos.len < 3:
      echo "Usage: nim r src/tools/run_report.nim <rom> <start.state> <log.tas> [--out bin/reports/x.md] [--frames N] [--stretch N]"
      echo "       nim r src/tools/run_report.nim --session <session-dir> [--stretch N] [--bookmarks-only]"
      quit(1)
    result.rom = pos[0]
    result.state = pos[1]
    result.tas = pos[2]
  if result.outPath.len == 0:
    result.outPath = defaultOutPath(result.tas)

proc main() =
  ## Replay the TAS headless, sample WRAM, write a markdown report.
  let args = parseArgs()
  if not isAllowedReportPath(args.outPath):
    echo "ERROR: report path must be under ", ReportOutDir, " (or '-' for stdout). Got: ", args.outPath
    quit(1)
  if not fileExists(args.rom):
    echo "ERROR: ROM not found: ", args.rom
    quit(1)
  if not fileExists(args.state):
    echo "ERROR: start state not found: ", args.state
    quit(1)
  if not fileExists(args.tas):
    echo "ERROR: tas not found: ", args.tas
    quit(1)

  let rom = readRom(args.rom)
  let romHash = romHashOf(rom)
  echo &"ROM: {args.rom}  hash=0x{romHash:08X}"
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()
  let data = cast[seq[byte]](readFile(args.state))
  deserializeState(data, snes, cpu)
  echo &"start state: {args.state}"

  let (rheader, deltas) = parseReplay(args.tas)
  echo &"tas: {args.tas}  magic={rheader.magic} cadence={rheader.cadence} deltas={deltas.len} build={rheader.buildCommit}"
  if rheader.romHash != 0 and rheader.romHash != romHash:
    echo &"WARNING: tas ROM hash 0x{rheader.romHash:08X} != current 0x{romHash:08X}"
  if isLegacyReplay(rheader) and not args.bookmarksOnly and args.stretch < 2:
    echo "ERROR: legacy TAS (no cadence emu). Re-record, or --legacy-stretch N"
    quit(1)

  var report = RunReport(
    romPath: args.rom,
    tasPath: args.tas,
    startStatePath: args.state,
    build: buildLabel(),
    romHash: romHash,
    tasRomHash: rheader.romHash,
  )
  let first = sampleFrame(snes, 0)
  seedReport(report, first)
  var last = first
  if args.bookmarksOnly:
    echo "skipping TAS replay (--bookmarks-only)"
    report.notes.add "TAS replay skipped (--bookmarks-only)."
  else:
    var maxFrames = args.frames
    if maxFrames < 0:
      maxFrames = lastDeltaFrame(deltas)
    if maxFrames < 0:
      maxFrames = 0
    var stretch = args.stretch
    if stretch < 1:
      stretch = 1
    echo &"replaying {maxFrames} TAS frames stretch={stretch} (no render)..."
    report.notes.add &"TAS replay stretch={stretch} (1 = one emu frame per TAS frame)."
    var prev = first
    var lastDlg = ""
    discard applyTas(snes, cpu, deltas, maxFrames, stretch = stretch,
      checkpoints = rheader.checkpoints,
      onFrame = proc(liveSnes: SnesBus, tf: int) =
        let live = getDialogueText(liveSnes)
        if usableDialogue(live) and live != lastDlg:
          if report.events.len > 0 and
              report.events[^1].kind == ekDialogue and
              live.startsWith(report.events[^1].detail):
            report.events[^1].detail = live
            report.events[^1].frame = tf
          else:
            report.events.add RunEvent(
              frame: tf, kind: ekDialogue, detail: live)
          lastDlg = live
        let cur = sampleFrame(liveSnes, tf)
        var curNoDlg = cur
        curNoDlg.dialogue = prev.dialogue
        appendDiffs(report.events, prev, curNoDlg)
        prev = cur
        last = cur
        if tf > 0 and tf mod 10000 == 0:
          echo &"  tas={tf}/{maxFrames} events={report.events.len} " &
            &"room={cur.room} pos=(0x{cur.posX:04X},0x{cur.posY:04X})"
    )
  finishReport(report, last, replay.wramHash(snes))
  if not args.bookmarksOnly and report.startPosX == 0 and report.endPosX == 0 and
      report.endRoom == "title":
    report.notes.add "Replay never left title at stretch=" & $args.stretch &
      ". Pre-fix movies need --stretch 2 (window-loop TAS). Try that before giving up."
  if args.session.len > 0:
    echo "sampling F12 bookmarks..."
    report.bookmarks = collectBookmarks(rom, args.session)
    if args.bookmarksOnly or report.events.len == 0:
      foldBookmarks(report)
  let md = renderMarkdown(report)
  if args.outPath == "-":
    stdout.write md
  else:
    createDir(parentDir(args.outPath))
    writeFile(args.outPath, md)
    echo &"wrote {args.outPath} ({report.events.len} events, {report.frames} frames)"

when isMainModule:
  main()
