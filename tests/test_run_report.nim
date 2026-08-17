## Collapse + markdown tests for the run-report library. No ROM, no TAS.

import
  std/strutils,
  ../src/decompbound/run_report

proc snap(role: string, level, hp: int, items: seq[string] = @[],
    inParty = true): PartySnap =
  ## Synthetic party member.
  PartySnap(
    role: role,
    name: role,
    level: level,
    exp: 0,
    hp: hp,
    hpMax: 20,
    inParty: inParty,
    items: items,
  )

proc baseSample(frame: int): FrameSample =
  ## Quiet overworld snapshot used as the mutation base.
  FrameSample(
    frame: frame,
    dialogue: "",
    inBattle: false,
    battleText: "",
    room: "bedroom",
    money: 0,
    posX: 1,
    posY: 2,
    spine: @[("tg", 25), ("pokey", 0)],
    members: @[snap("Ness", 1, 18)],
  )

proc testDialogueCollapse() =
  ## Same dialogue across many frames is one event; a change is a second.
  var events: seq[RunEvent] = @[]
  var prev = baseSample(0)
  prev.dialogue = "aaa"
  for i in 1 .. 10:
    var cur = prev
    cur.frame = i
    cur.dialogue = "aaa"
    appendDiffs(events, prev, cur)
    prev = cur
  doAssert events.len == 0
  var changed = prev
  changed.frame = 11
  changed.dialogue = "bbb"
  appendDiffs(events, prev, changed)
  doAssert events.len == 1
  doAssert events[0].kind == ekDialogue
  doAssert events[0].frame == 11
  doAssert events[0].detail == "bbb"

proc testLevelUp() =
  ## Level 1 → 2 emits one level_up.
  var events: seq[RunEvent] = @[]
  let prev = baseSample(0)
  var cur = baseSample(40)
  cur.members = @[snap("Ness", 2, 18)]
  appendDiffs(events, prev, cur)
  doAssert events.len == 1
  doAssert events[0].kind == ekLevelUp
  doAssert events[0].detail == "Ness 1 -> 2"

proc testStoryAndBattle() =
  ## Spine change, battle enter/exit, death, items, room, money.
  var events: seq[RunEvent] = @[]
  let prev = baseSample(0)
  var cur = baseSample(5)
  cur.spine = @[("tg", 75), ("pokey", 0)]
  cur.room = "hall"
  cur.money = 12
  cur.inBattle = true
  cur.battleText = "ccc"
  cur.members = @[snap("Ness", 1, 18, @["x"])]
  appendDiffs(events, prev, cur)
  var kinds: seq[EventKind] = @[]
  for e in events:
    kinds.add e.kind
  doAssert ekStory in kinds
  doAssert ekRoom in kinds
  doAssert ekMoney in kinds
  doAssert ekBattleEnter in kinds
  doAssert ekItem in kinds
  var after = cur
  after.frame = 9
  after.inBattle = false
  after.members = @[snap("Ness", 1, 0, @["x"])]
  var ev2: seq[RunEvent] = @[]
  appendDiffs(ev2, cur, after)
  var kinds2: seq[EventKind] = @[]
  for e in ev2:
    kinds2.add e.kind
  doAssert ekBattleExit in kinds2
  doAssert ekDeath in kinds2

proc testMarkdownHeaders() =
  ## Renderer emits the section headers from a synthetic report.
  var r = RunReport(
    romPath: "rom",
    tasPath: "a.tas",
    startStatePath: "a.state",
    build: "test",
    romHash: 1,
    tasRomHash: 1,
    frames: 11,
    startRoom: "bedroom",
    endRoom: "hall",
  )
  var prev = baseSample(0)
  prev.dialogue = "aaa"
  seedReport(r, prev)
  var cur = baseSample(11)
  cur.dialogue = "bbb"
  cur.members = @[snap("Ness", 2, 18)]
  appendDiffs(r.events, prev, cur)
  finishReport(r, cur, 0)
  r.bookmarks.add Bookmark(name: "shot.png", sample: cur)
  r.notes.add "synthetic note"
  let md = renderMarkdown(r)
  for h in ["# Run report", "## Notes", "## Bookmarks", "## Story beats",
            "## Party", "## Battles", "## Inventory", "## Dialogue",
            "## Event log"]:
    doAssert h in md, "missing header: " & h
  doAssert "aaa" notin md or "bbb" in md
  doAssert "Ness 1 -> 2" in md

proc testFoldBookmarks() =
  ## Consecutive F12 snaps become a timeline (level-up + room).
  var a = baseSample(0)
  a.room = "bedroom"
  var b = baseSample(0)
  b.room = "outside_onett"
  b.members = @[snap("Ness", 2, 18)]
  var r = RunReport()
  r.bookmarks = @[
    Bookmark(name: "earthbound_20260816-183333.png", sample: a),
    Bookmark(name: "earthbound_20260816-184046.png", sample: b),
  ]
  foldBookmarks(r)
  doAssert r.startRoom == "bedroom"
  doAssert r.endRoom == "outside_onett"
  var kinds: seq[EventKind] = @[]
  for e in r.events:
    kinds.add e.kind
  doAssert ekRoom in kinds
  doAssert ekLevelUp in kinds
  doAssert r.events[0].frame == 184046 or r.events[^1].frame == 184046

proc testRoomAndBattleClean() =
  ## Arcade is not Ness's bedroom; battle fragments drop.
  doAssert reportRoomLabel(0x1FB8, 0x0452, false) == "ness_bedroom"
  doAssert reportRoomLabel(0x1F28, 0x02C8, false) == "onett_arcade"
  doAssert reportRoomLabel(0x1B8E, 0x0358, false) == "minch_house"
  doAssert reportRoomLabel(0x081B, 0x0079, false) == "meteor_crater"
  doAssert reportRoomLabel(0x0648, 0x048D, false) == "onett_downtown"
  doAssert reportRoomLabel(0x09E9, 0x020E, true) == "battle"
  doAssert reportRoomLabel(0, 0, false) == "title"
  let cleaned = cleanBattleText(
    "Ness\ness\neapons\nBash\nGoods\nout\nDefend\noll\nw Game\n" &
    "Auto Fight\nRun Away\nPSI\ncard\nCracked bat\nStarman Junior")
  doAssert "Bash" in cleaned
  doAssert "Starman Junior" in cleaned
  doAssert "Cracked bat" notin cleaned
  doAssert "Banana flavor" notin cleaned
  doAssert "eapons" notin cleaned
  doAssert "w Game" notin cleaned
  for ln in cleaned.splitLines:
    doAssert ln != "ess"
    doAssert ln != "out"
    doAssert ln != "card"

proc testUsableDialogue() =
  ## Torn stream cursors are not dialogue.
  doAssert not usableDialogue("L want to \n>")
  doAssert not usableDialogue("U")
  doAssert not usableDialogue(">")
  doAssert usableDialogue("I want to go home now.")

proc testLatchSpine() =
  ## Indoor tg drop does not emit a story beat after outdoor 100.
  var a = baseSample(0)
  a.spine = @[("tg", 100), ("pokey", 10)]
  var b = baseSample(1)
  b.spine = @[("tg", 25), ("pokey", 10)]
  var samples = @[a, b]
  latchHeadlineSpine(samples)
  doAssert samples[1].spine == @[("tg", 100), ("pokey", 10)]
  var events: seq[RunEvent] = @[]
  appendDiffs(events, samples[0], samples[1])
  for e in events:
    doAssert e.kind != ekStory

proc testNoFakeLevelOrBitpop() =
  ## Benchwarmers and bitpop do not become story/level events.
  var events: seq[RunEvent] = @[]
  var prev = baseSample(0)
  prev.members.add snap("Poo", 0, 0, inParty = false)
  prev.spine.add ("bitpop", 10)
  var cur = baseSample(3)
  cur.members.add snap("Poo", 15, 100, inParty = false)
  cur.spine = @[("tg", 25), ("pokey", 0), ("bitpop", 40)]
  appendDiffs(events, prev, cur)
  for e in events:
    doAssert e.kind != ekLevelUp or "Poo" notin e.detail
    doAssert not e.detail.startsWith("bitpop")

proc testAllowedPath() =
  ## Only bin/reports (and stdout) may receive a report.
  doAssert isAllowedReportPath("bin/reports/x.md")
  doAssert isAllowedReportPath("-")
  doAssert not isAllowedReportPath("docs/x.md")
  doAssert not isAllowedReportPath("docs/2026-08-16-fast-text-tas.md")
  doAssert not isAllowedReportPath("/tmp/x.md")

testDialogueCollapse()
testLevelUp()
testStoryAndBattle()
testMarkdownHeaders()
testFoldBookmarks()
testRoomAndBattleClean()
testUsableDialogue()
testLatchSpine()
testNoFakeLevelOrBitpop()
testAllowedPath()
