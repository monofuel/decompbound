## Collapsed event log + markdown renderer for a TAS / bot-run report.
## The CLI (`src/tools/run_report.nim`) fills FrameSample from live WRAM.
## This module never talks to the emulator — tests feed synthetic snapshots.

import
  std/[algorithm, os, strformat, strutils, tables]

const
  ReportOutDir* = "bin/reports"
  ## Story keys that mean something on a sparse F12 timeline. bitpop and
  ## midgame stubs fire on leftover WRAM and drown the real prologue.
  SpineEventKeys* = ["tg", "pokey", "pokey_knock", "buzzbuzz", "sunrise", "frank"]

proc usableDialogue*(s: string): bool =
  ## Reject torn $96C5 decodes (single-letter lead-in, lone prompt glyphs).
  let t = s.strip()
  if t.len < 8:
    return false
  if t == ">" or t == ">>":
    return false
  let first = t.splitWhitespace()
  if first.len == 0:
    return false
  if first[0].len == 1 and first[0] notin ["I", "A"]:
    return false
  true

proc cleanBattleText*(raw: string): string =
  ## Command menu + enemy names. Inventory and flavor strings live in the
  ## same window RAM and are not the fight.
  const
    Menu = ["Ness", "Paula", "Jeff", "Poo", "Bash", "Goods", "PSI", "Defend",
            "Auto Fight", "Run Away"]
    Noise = ["flavor", "Cookie", "Bread", "bat", "Hamburger", "card", "cap",
             "None", "Null", "juice"]
  var kept: seq[string] = @[]
  for rawLine in raw.splitLines:
    let s = rawLine.strip()
    if s.len < 3 or s[0] notin {'A'..'Z'}:
      continue
    var skip = false
    for n in Noise:
      if n in s:
        skip = true
        break
    if skip:
      continue
    if s in Menu or s.startsWith("Starman") or s.startsWith("Auto") or
        s.startsWith("Run "):
      kept.add s
      continue
    # Enemy-ish: two Title-Case words, no digits.
    if s.contains(' ') and s.len >= 6:
      var ok = true
      for w in s.split(' '):
        if w.len == 0 or w[0] notin {'A'..'Z'}:
          ok = false
      if ok:
        kept.add s
  kept.join("\n")

proc reportRoomLabel*(px, py: int, inBattle: bool): string =
  ## Room name from world pos. Sector $89CA is FFFF on many F12s, so coords only.
  ## Indoor arcade sits in the same X band as Ness's bedroom at a lower Y.
  if inBattle:
    return "battle"
  if px < 0x0100 and py < 0x0100:
    return "title"
  if px >= 0x1F00 and px < 0x2000 and py >= 0x0400 and py < 0x0580:
    return "ness_bedroom"
  if px >= 0x1E00 and px < 0x2000 and py >= 0x0240 and py < 0x0380:
    return "onett_arcade"
  if px >= 0x1A80 and px < 0x1D00 and py >= 0x0280 and py < 0x0400:
    return "minch_house"
  if px >= 0x1D00 and px < 0x2100 and py <= 0x0C00:
    return "ness_house"
  if px >= 0x1C00:
    return "indoor"
  const
    Marks = [
      ("meteor_crater", 0x0858, 0x00F2, 0xC0),
      ("ness_door", 0x0A60, 0x0158, 0x80),
      ("onett_hill", 0x05F8, 0x0148, 0xC0),
      ("onett_downtown", 0x0640, 0x04A0, 0x180),
    ]
  for (name, mx, my, rad) in Marks:
    if abs(px - mx) + abs(py - my) <= rad:
      return name
  "onett_overworld"

type
  EventKind* = enum
    ## One class of collapsed run event.
    ekDialogue
    ekBattleEnter
    ekBattleExit
    ekBattleText
    ekStory
    ekLevelUp
    ekItem
    ekRoom
    ekDeath
    ekMoney

  RunEvent* = object
    ## One collapsed change at a frame.
    frame*: int
    kind*: EventKind
    detail*: string

  PartySnap* = object
    ## One character at a sample (ids only — names come from the CLI).
    role*: string
    name*: string
    level*: int
    exp*: int
    hp*: int
    hpMax*: int
    inParty*: bool
    items*: seq[string]

  FrameSample* = object
    ## WRAM snapshot for one frame. Empty fields are valid (title screen).
    frame*: int
    dialogue*: string
    inBattle*: bool
    battleText*: string
    room*: string
    money*: int
    posX*: int
    posY*: int
    spine*: seq[(string, int)]
    members*: seq[PartySnap]

  Bookmark* = object
    ## One F12 / ebSt snapshot sampled without replaying the TAS.
    name*: string
    sample*: FrameSample

  RunReport* = object
    ## Finished report ready to render.
    romPath*: string
    tasPath*: string
    startStatePath*: string
    build*: string
    romHash*: uint32
    tasRomHash*: uint32
    frames*: int
    startPosX*, startPosY*: int
    endPosX*, endPosY*: int
    wramHash*: uint32
    startMoney*, endMoney*: int
    startRoom*, endRoom*: string
    startMembers*, endMembers*: seq[PartySnap]
    startSpine*, endSpine*: seq[(string, int)]
    events*: seq[RunEvent]
    bookmarks*: seq[Bookmark]
    notes*: seq[string]

proc eventKindName*(k: EventKind): string =
  ## Stable lowercase tag for markdown / logs.
  case k
  of ekDialogue: "dialogue"
  of ekBattleEnter: "battle_enter"
  of ekBattleExit: "battle_exit"
  of ekBattleText: "battle_text"
  of ekStory: "story"
  of ekLevelUp: "level_up"
  of ekItem: "item"
  of ekRoom: "room"
  of ekDeath: "death"
  of ekMoney: "money"

proc isAllowedReportPath*(path: string): bool =
  ## True only for paths under bin/reports/ (gitignored). Reports carry game text.
  if path.len == 0:
    return false
  if path == "-":
    return true
  let n = path.replace('\\', '/').normalizedPath
  result = n == ReportOutDir or n.startsWith(ReportOutDir & "/") or
    n.contains("/" & ReportOutDir & "/")

proc itemBag(items: seq[string]): CountTable[string] =
  ## Multiset of inventory labels.
  result = initCountTable[string]()
  for it in items:
    result.inc(it)

proc bagDiff(a, b: CountTable[string]): string =
  ## Compact "+x -y" from two item bags. Empty if equal.
  var added: seq[string] = @[]
  var removed: seq[string] = @[]
  var keys: seq[string] = @[]
  for k in a.keys:
    keys.add k
  for k in b.keys:
    if k notin a:
      keys.add k
  keys.sort()
  for k in keys:
    let da = a.getOrDefault(k)
    let db = b.getOrDefault(k)
    if db > da:
      for i in 0 ..< (db - da):
        added.add k
    elif da > db:
      for i in 0 ..< (da - db):
        removed.add k
  var parts: seq[string] = @[]
  for x in added:
    parts.add "+" & x
  for x in removed:
    parts.add "-" & x
  parts.join(" ")

proc memberByRole(members: seq[PartySnap], role: string): PartySnap =
  ## Find a member by role, or an empty snap.
  for m in members:
    if m.role == role:
      return m

proc appendDiffs*(events: var seq[RunEvent], prev, cur: FrameSample) =
  ## Append collapsed events for changes from prev → cur. First sample is seed.
  if cur.dialogue != prev.dialogue:
    events.add RunEvent(frame: cur.frame, kind: ekDialogue, detail: cur.dialogue)
  if cur.inBattle and not prev.inBattle:
    events.add RunEvent(frame: cur.frame, kind: ekBattleEnter, detail: cur.battleText)
  elif prev.inBattle and not cur.inBattle:
    events.add RunEvent(frame: cur.frame, kind: ekBattleExit, detail: prev.battleText)
  if cur.inBattle and prev.inBattle and cur.battleText != prev.battleText:
    events.add RunEvent(frame: cur.frame, kind: ekBattleText, detail: cur.battleText)
  if cur.room != prev.room:
    events.add RunEvent(frame: cur.frame, kind: ekRoom,
      detail: prev.room & " -> " & cur.room)
  if cur.money != prev.money:
    events.add RunEvent(frame: cur.frame, kind: ekMoney,
      detail: $prev.money & " -> " & $cur.money)
  var prevSpine = initTable[string, int]()
  for (k, v) in prev.spine:
    prevSpine[k] = v
  for (k, v) in cur.spine:
    if k notin SpineEventKeys:
      continue
    if not prevSpine.hasKey(k) or prevSpine[k] != v:
      let oldV = prevSpine.getOrDefault(k)
      events.add RunEvent(frame: cur.frame, kind: ekStory,
        detail: k & " " & $oldV & " -> " & $v)
  for m in cur.members:
    if not m.inParty:
      continue
    let p = memberByRole(prev.members, m.role)
    if p.role.len == 0:
      continue
    if m.level > p.level and p.level > 0:
      events.add RunEvent(frame: cur.frame, kind: ekLevelUp,
        detail: m.role & " " & $p.level & " -> " & $m.level)
    if p.hp > 0 and m.hp == 0:
      events.add RunEvent(frame: cur.frame, kind: ekDeath,
        detail: m.role & " hp " & $p.hp & " -> 0")
    if p.inParty or p.items.len > 0:
      let d = bagDiff(itemBag(p.items), itemBag(m.items))
      if d.len > 0:
        events.add RunEvent(frame: cur.frame, kind: ekItem,
          detail: m.role & " " & d)

proc latchHeadlineSpine*(samples: var seq[FrameSample]) =
  ## Monotonic max on headline story keys so indoor/scorer bounce is not a beat.
  var peak = initTable[string, int]()
  for i in 0 ..< samples.len:
    var next: seq[(string, int)] = @[]
    for (k, v) in samples[i].spine:
      if k notin SpineEventKeys:
        continue
      let m = max(peak.getOrDefault(k), v)
      peak[k] = m
      next.add (k, m)
    samples[i].spine = next

proc seedReport*(r: var RunReport, first: FrameSample) =
  ## Record the first sample as the start snapshot. No events yet.
  r.startPosX = first.posX
  r.startPosY = first.posY
  r.startMoney = first.money
  r.startRoom = first.room
  r.startMembers = first.members
  r.startSpine = first.spine

proc finishReport*(r: var RunReport, last: FrameSample, wramHash: uint32) =
  ## Record the last sample as the end snapshot.
  r.frames = last.frame
  r.endPosX = last.posX
  r.endPosY = last.posY
  r.endMoney = last.money
  r.endRoom = last.room
  r.endMembers = last.members
  r.endSpine = last.spine
  r.wramHash = wramHash

proc fmtPos(x, y: int): string =
  ## Hex world position.
  &"(0x{x:04X}, 0x{y:04X})"

proc fmtMember(m: PartySnap): string =
  ## One party line.
  let party = if m.inParty: "in" else: "out"
  result = &"{m.role} {m.name} Lv{m.level} HP {m.hp}/{m.hpMax} EXP {m.exp} [{party}]"
  if m.items.len > 0:
    result.add " items=" & m.items.join(",")

proc bookmarkStamp*(name: string): int =
  ## Parse HHMMSS from earthbound_YYYYMMDD-HHMMSS.png; 0 if absent.
  let base = name.changeFileExt("")
  let dash = base.rfind('-')
  if dash < 0 or dash == base.high:
    return 0
  try:
    result = parseInt(base[dash + 1 .. ^1])
  except ValueError:
    result = 0

proc foldBookmarks*(r: var RunReport) =
  ## Build the event timeline + start/end from F12 bookmarks.
  ## Used when TAS replay is skipped or did not leave the start seat.
  if r.bookmarks.len == 0:
    return
  var stamped: seq[FrameSample] = @[]
  var seedIdx = 0
  var foundParty = false
  for i, b in r.bookmarks:
    var s = b.sample
    s.frame = bookmarkStamp(b.name)
    stamped.add s
    if not foundParty:
      for m in s.members:
        if m.inParty:
          seedIdx = i
          foundParty = true
          break
  latchHeadlineSpine(stamped)
  for i, s in stamped:
    r.bookmarks[i].sample.spine = s.spine
  seedReport(r, stamped[seedIdx])
  var prev = stamped[0]
  for i in 1 ..< stamped.len:
    appendDiffs(r.events, prev, stamped[i])
    prev = stamped[i]
  finishReport(r, stamped[^1], r.wramHash)

proc renderMarkdown*(r: RunReport): string =
  ## Render the report as markdown. May contain game text — write only to bin/reports/.
  var lines: seq[string] = @[]
  lines.add "# Run report"
  lines.add ""
  lines.add &"- **TAS:** `{r.tasPath}`"
  lines.add &"- **Start state:** `{r.startStatePath}`"
  lines.add &"- **ROM:** `{r.romPath}` hash `0x{r.romHash:08X}` (tas `0x{r.tasRomHash:08X}`)"
  if r.build.len > 0:
    lines.add &"- **Build:** `{r.build}`"
  lines.add &"- **Frames:** {r.frames}"
  lines.add &"- **Pos:** {fmtPos(r.startPosX, r.startPosY)} → {fmtPos(r.endPosX, r.endPosY)}"
  lines.add &"- **Room:** {r.startRoom} → {r.endRoom}"
  lines.add &"- **Money:** {r.startMoney} → {r.endMoney}"
  lines.add &"- **WRAM hash:** `0x{r.wramHash:08X}`"
  lines.add &"- **Events:** {r.events.len}"
  if r.bookmarks.len > 0:
    lines.add &"- **Bookmarks:** {r.bookmarks.len}"
  if r.notes.len > 0:
    lines.add ""
    lines.add "## Notes"
    lines.add ""
    for n in r.notes:
      lines.add "- " & n
  lines.add ""
  if r.bookmarks.len > 0:
    lines.add "## Bookmarks"
    lines.add ""
    for b in r.bookmarks:
      let s = b.sample
      lines.add &"### {b.name}"
      lines.add &"- pos {fmtPos(s.posX, s.posY)}  room `{s.room}`  money {s.money}  battle={s.inBattle}"
      var spineBits: seq[string] = @[]
      for (k, v) in s.spine:
        if v != 0:
          spineBits.add k & "=" & $v
      if spineBits.len > 0:
        lines.add "- spine: " & spineBits.join(" ")
      if s.members.len == 0:
        lines.add "- party: (empty)"
      else:
        for m in s.members:
          if m.inParty:
            lines.add "- " & fmtMember(m)
      if s.dialogue.len > 0:
        lines.add "- dialogue:"
        for ln in s.dialogue.splitLines:
          lines.add "  " & ln
      if s.inBattle and s.battleText.len > 0:
        lines.add "- battle:"
        for ln in s.battleText.splitLines:
          lines.add "  " & ln
      lines.add ""
  lines.add "## Story beats"
  lines.add ""
  var anyStory = false
  for e in r.events:
    if e.kind == ekStory:
      lines.add &"- f{e.frame}: {e.detail}"
      anyStory = true
  if not anyStory:
    lines.add "- (none)"
  lines.add ""
  lines.add "## Party"
  lines.add ""
  lines.add "Start:"
  var anyStart = false
  for m in r.startMembers:
    if m.inParty:
      lines.add "- " & fmtMember(m)
      anyStart = true
  if not anyStart:
    lines.add "- (empty)"
  lines.add ""
  lines.add "End:"
  var anyEnd = false
  for m in r.endMembers:
    if m.inParty:
      lines.add "- " & fmtMember(m)
      anyEnd = true
  if not anyEnd:
    lines.add "- (empty)"
  lines.add ""
  lines.add "Level-ups:"
  var anyLv = false
  for e in r.events:
    if e.kind == ekLevelUp:
      lines.add &"- f{e.frame}: {e.detail}"
      anyLv = true
  if not anyLv:
    lines.add "- (none)"
  lines.add ""
  lines.add "## Battles"
  lines.add ""
  var anyBattle = false
  for e in r.events:
    if e.kind in {ekBattleEnter, ekBattleExit, ekBattleText, ekDeath}:
      lines.add &"- f{e.frame} {eventKindName(e.kind)}: {e.detail}"
      anyBattle = true
  if not anyBattle:
    lines.add "- (none)"
  lines.add ""
  lines.add "## Inventory"
  lines.add ""
  var anyItem = false
  for e in r.events:
    if e.kind == ekItem:
      lines.add &"- f{e.frame}: {e.detail}"
      anyItem = true
  if not anyItem:
    lines.add "- (none)"
  lines.add ""
  lines.add "## Dialogue"
  lines.add ""
  var anyDlg = false
  for e in r.events:
    if e.kind == ekDialogue:
      if e.detail.len == 0:
        lines.add &"- f{e.frame}: *(window closed)*"
      else:
        lines.add &"- f{e.frame}:"
        for ln in e.detail.splitLines:
          lines.add "  " & ln
      anyDlg = true
  if not anyDlg:
    lines.add "- (none)"
  lines.add ""
  lines.add "## Event log"
  lines.add ""
  if r.events.len == 0:
    lines.add "- (none)"
  else:
    for e in r.events:
      var d = e.detail
      d = d.replace('\n', ' ')
      if d.len > 120:
        d = d[0 ..< 117] & "..."
      lines.add &"- f{e.frame} `{eventKindName(e.kind)}` {d}"
  lines.add ""
  lines.join("\n")
