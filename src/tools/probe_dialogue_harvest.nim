## NPC dialogue harvester: walk up to nearby entities, press A, capture real text.
## Writes [game]-tagged lines into decompbound_secret/knowledge/ (and known NPCs).
## LEGIT movement only (d-pad + collision). Pattern from probe_knock_door_ents.

import
  std/[os, strformat, strutils, times],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ./[touch_grass, scene]

const
  RomPath = "bin/Earthbound (U) [!].smc"
  KnowledgeDir = "../decompbound_secret/knowledge"
  LogPath = KnowledgeDir / "dialogue_log.md"
  Right = 0x0100'u16
  Left = 0x0200'u16
  Down = 0x0400'u16
  Up = 0x0800'u16
  BtnA = 0x0080'u16
  BtnB = 0x8000'u16
  # Stand ~one tile off the entity so face+A can hit the talk trigger.
  AdjacentPx = 16
  # Pixel tolerance when steering toward the approach tile.
  AlignTol = 4
  # Max frames to walk toward one entity before giving up.
  WalkBudget = 900
  # Max frames of face+A + advance after arriving.
  TalkBudget = 500
  # Idle settle after load so entity AI / windows stabilize.
  SettleFrames = 40
  # Stuck-frame threshold for lateral wiggle while walking.
  StuckWiggle = 20
  States = [
    "bin/states/llm/pokey_free.state",
    "bin/states/llm/onett_start.state",
  ]
  # Attribute only via entity identity / name when available — never match on
  # game dialogue literals (copyright hygiene).

type
  Capture = object
    state: string
    slot: int
    dir: string
    distTiles: int
    entX, entY: int
    px, py: int
    dialogue: string
    note: string

proc playerPos(snes: SnesBus): (int, int) =
  ## Slot-24 world position.
  let i = PlayerSlot * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc windowOpen(snes: SnesBus): bool =
  ## True when either text window slot is allocated.
  readU8(snes, 0x8650) != 0xFF or readU8(snes, 0x8654) != 0xFF

proc hold(snes: SnesBus, c: var Cpu, img: Image, mask: uint16, n: int) =
  ## Hold a joypad mask for n frames.
  for i in 0 ..< n:
    snes.joy1 = mask
    policy.stepOneFrame(snes, c, img)
  snes.joy1 = 0

proc settle(snes: SnesBus, c: var Cpu, img: Image) =
  ## Idle a few frames after state load.
  hold(snes, c, img, 0, SettleFrames)

proc faceMask(dx, dy: int): uint16 =
  ## Dominant-axis facing toward entity (EB: +x east, +y south).
  if abs(dx) >= abs(dy):
    if dx > 0: Right else: Left
  else:
    if dy > 0: Down else: Up

proc approachTarget(ex, ey, px, py: int): (int, int, uint16) =
  ## Pixel to stand on + face mask so we look at the entity from one tile out.
  let dx = ex - px
  let dy = ey - py
  if abs(dx) >= abs(dy):
    if dx >= 0:
      (ex - AdjacentPx, ey, Right)
    else:
      (ex + AdjacentPx, ey, Left)
  else:
    if dy >= 0:
      (ex, ey - AdjacentPx, Down)
    else:
      (ex, ey + AdjacentPx, Up)

proc walkToward(
    snes: SnesBus, c: var Cpu, img: Image, tx, ty: int
): bool =
  ## D-pad walk to (tx,ty) within AlignTol. Returns true if arrived.
  var stuck = 0
  var lastX = -1
  var lastY = -1
  for f in 0 ..< WalkBudget:
    let (px, py) = playerPos(snes)
    if abs(px - tx) <= AlignTol and abs(py - ty) <= AlignTol:
      return true
    if px == lastX and py == lastY:
      inc stuck
    else:
      stuck = 0
    lastX = px
    lastY = py
    var j = 0'u16
    # Prefer axis with larger remaining error so we don't slide past corners.
    let ex = tx - px
    let ey = ty - py
    if stuck > StuckWiggle:
      # Lateral wiggle when collision blocks the direct path.
      j = if (stuck div 8) mod 2 == 0: Left else: Right
      if abs(ey) > AlignTol:
        j = j or (if ey > 0: Down else: Up)
    elif abs(ex) >= abs(ey) and abs(ex) > AlignTol:
      j = if ex > 0: Right else: Left
    elif abs(ey) > AlignTol:
      j = if ey > 0: Down else: Up
    else:
      if abs(ex) > AlignTol:
        j = if ex > 0: Right else: Left
      if abs(ey) > AlignTol:
        j = j or (if ey > 0: Down else: Up)
    snes.joy1 = j
    policy.stepOneFrame(snes, c, img)
    # Indoor teleport mid-walk (door) — abort this attempt.
    let (nx, _) = playerPos(snes)
    if nx >= 0x1C00 and px < 0x1C00:
      return false
  false

proc dismissMenu(snes: SnesBus, c: var Cpu, img: Image) =
  ## B-out of overworld command menu if open without real dialogue text.
  for i in 0 ..< 40:
    if not windowOpen(snes):
      break
    let dlg = policy.getDialogueText(snes)
    if dlg.len > 0:
      break
    snes.joy1 = if i mod 6 < 2: BtnB else: 0
    policy.stepOneFrame(snes, c, img)
  snes.joy1 = 0

proc finalizePage(pages: var seq[string], current: string) =
  ## Keep only completed page text (drop typewriter prefixes).
  let t = current.strip()
  if t.len == 0:
    return
  # Skip if this is a pure prefix of something already recorded, or vice-versa.
  for i, p in pages:
    if t == p:
      return
    if t.startsWith(p) and t.len > p.len:
      pages[i] = t
      return
    if p.startsWith(t):
      return
  pages.add t

proc talkAndCapture(
    snes: SnesBus, c: var Cpu, img: Image, face: uint16
): string =
  ## Face entity, A-interact, advance windows; return finalized dialogue pages.
  ## getDialogueText streams typewriter growth — only commit a page when the
  ## text stops expanding for StableFrames, or the window flips to a new msg.
  const StableFrames = 18
  var pages: seq[string]
  var current = ""
  var stable = 0
  var sawWindow = false
  for f in 0 ..< TalkBudget:
    let open = windowOpen(snes)
    if open:
      sawWindow = true
      let dlg = policy.getDialogueText(snes).strip()
      if dlg.len == 0:
        # Window open but no stream yet (menu / face graphic) — try B later.
        discard
      elif dlg == current:
        inc stable
        if stable == StableFrames:
          finalizePage(pages, current)
      elif current.len > 0 and dlg.startsWith(current):
        # Typewriter growth of the same page.
        current = dlg
        stable = 0
      elif current.len > 0 and current.startsWith(dlg) and dlg.len < current.len:
        # Stream rewound / next page started shorter — commit previous.
        finalizePage(pages, current)
        current = dlg
        stable = 0
      else:
        # Different message (or first text).
        if current.len > 0:
          finalizePage(pages, current)
        current = dlg
        stable = 0
      # Advance: short A edges while window open.
      snes.joy1 = if f mod 8 < 2: BtnA else: 0
    else:
      if sawWindow:
        # Window closed — commit last page and stop.
        finalizePage(pages, current)
        current = ""
        break
      # Face + A pulse until something opens (or budget ends).
      if f < 120:
        if f mod 20 < 12:
          snes.joy1 = face
        elif f mod 20 < 16:
          snes.joy1 = BtnA
        else:
          snes.joy1 = 0
      else:
        snes.joy1 = if f mod 16 < 3: BtnA else: 0
        if f > 200 and pages.len == 0:
          break
    policy.stepOneFrame(snes, c, img)
    # Menu with no dialogue stream: B out and stop.
    if windowOpen(snes) and policy.getDialogueText(snes).len == 0 and f > 40:
      dismissMenu(snes, c, img)
      if pages.len == 0 and current.len == 0:
        break
  # Drain remaining dialogue if still open.
  for i in 0 ..< 240:
    if not windowOpen(snes):
      finalizePage(pages, current)
      break
    let dlg = policy.getDialogueText(snes).strip()
    if dlg.len > 0:
      if dlg == current:
        inc stable
        if stable == StableFrames:
          finalizePage(pages, current)
      elif current.len > 0 and dlg.startsWith(current):
        current = dlg
        stable = 0
      else:
        if current.len > 0:
          finalizePage(pages, current)
        current = dlg
        stable = 0
    snes.joy1 = if i mod 8 < 2: BtnA else: 0
    policy.stepOneFrame(snes, c, img)
  finalizePage(pages, current)
  snes.joy1 = 0
  if pages.len > 1:
    result = pages.join(" | ")
  elif pages.len == 1:
    result = pages[0]
  else:
    result = ""

proc harvestEntity(
    snes: SnesBus, c: var Cpu, img: Image,
    statePath: string, ent: SceneEntity
): Capture =
  ## Reload state, walk adjacent to ent, talk, return capture record.
  result = Capture(
    state: statePath.extractFilename,
    slot: ent.slot,
    dir: ent.dir,
    distTiles: ent.distTiles,
    entX: ent.x,
    entY: ent.y,
  )
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  settle(snes, c, img)
  # Re-read entity pos after settle (movers may shift).
  let i = ent.slot * SlotIndexStride
  let ex = readU16(snes, WorldXBase + i)
  let ey = readU16(snes, WorldYBase + i)
  result.entX = ex
  result.entY = ey
  if (ex == 0 and ey == 0) or ex == 0xFFFF:
    result.note = "entity vanished after settle"
    return
  let (px0, py0) = playerPos(snes)
  let (tx, ty, _) = approachTarget(ex, ey, px0, py0)
  let arrived = walkToward(snes, c, img, tx, ty)
  let (px, py) = playerPos(snes)
  result.px = px
  result.py = py
  if not arrived:
    # Still try talk if we got reasonably close (within ~3 tiles).
    let dist = (abs(px - ex) + abs(py - ey)) div 8
    if dist > 6:
      result.note = &"unreachable (approach 0x{tx:04X},0x{ty:04X})"
      return
    result.note = "partial approach"
  # Face from actual final offset (entity may have moved).
  let faceNow = faceMask(ex - px, ey - py)
  result.dialogue = talkAndCapture(snes, c, img, faceNow)
  let (px2, py2) = playerPos(snes)
  result.px = px2
  result.py = py2
  if result.dialogue.len == 0 and result.note.len == 0:
    result.note = "no talk text"

proc appendLog(captures: seq[Capture]) =
  ## Append [game] lines to the secret dialogue log.
  createDir(KnowledgeDir)
  var body = ""
  if not fileExists(LogPath):
    body = """# Dialogue log

Captured NPC / object dialogue from live states via `probe_dialogue_harvest`.
Every line is ground truth from `policy.getDialogueText` — not model memory.

"""
  else:
    body = readFile(LogPath)
    if not body.endsWith("\n"):
      body.add "\n"
  body.add &"\n## Harvest {now().utc.format(\"yyyy-MM-dd HH:mm'Z'\")}\n\n"
  for cap in captures:
    let text =
      if cap.dialogue.len > 0: cap.dialogue.replace("\n", " ")
      else: "(empty)"
    let note =
      if cap.note.len > 0: &" — {cap.note}"
      else: ""
    body.add &"- [game] `{cap.state}` slot {cap.slot} ({cap.dir}, {cap.distTiles}t) " &
      &"player=(0x{cap.px:04X},0x{cap.py:04X}) ent=(0x{cap.entX:04X},0x{cap.entY:04X}): " &
      &"\"{text}\"{note}\n"
  writeFile(LogPath, body)

proc maybeAttribute(cap: Capture) =
  ## Optional NPC file attribution. Matching on dialogue *literals* is avoided
  ## so public source stays free of game text; use entity identity instead.
  discard cap

proc main() =
  ## Harvest dialogue from nearby entities on the listed states.
  if not fileExists(RomPath):
    raise newException(IOError, &"ROM missing: {RomPath}")
  let snes = newSnesBus(policy.readRomFile(RomPath))
  var c = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  var all: seq[Capture]

  for statePath in States:
    if not fileExists(statePath):
      echo &"SKIP missing state {statePath}"
      continue
    deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
    settle(snes, c, img)
    let sc = buildScene(snes)
    echo &"\n==== {statePath} player=(0x{sc.px:04X},0x{sc.py:04X}) room={sc.room} ents={sc.ents.len} ===="
    for ent in sc.ents:
      echo &"  try slot {ent.slot} ({ent.dir}, {ent.distTiles}t) @ (0x{ent.x:04X},0x{ent.y:04X})"
      let cap = harvestEntity(snes, c, img, statePath, ent)
      all.add cap
      let text =
        if cap.dialogue.len > 0: cap.dialogue
        else: "(empty)"
      let note =
        if cap.note.len > 0: &" [{cap.note}]"
        else: ""
      echo &"  {cap.state} / slot {cap.slot} ({cap.dir},{cap.distTiles}): {text}{note}"
      maybeAttribute(cap)

  appendLog(all)
  echo &"\nWrote {all.len} entries to {LogPath}"
  var hits = 0
  for cap in all:
    if cap.dialogue.len > 0:
      inc hits
  echo &"Non-empty captures: {hits}/{all.len}"

when isMainModule:
  main()
