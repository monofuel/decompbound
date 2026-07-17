## Structured scene representation for the LLM-play bot — perception channel #2
## (the fast, deterministic one; vision is the ~138s/call supplement).
##
## Built from WRAM each tick so the bot can navigate by INTENT — relative
## directions/distances to nearby entities — instead of spoon-fed coordinates.
## "Mom is 2 tiles north" replaces "navTo(0x0A60,0x0158)". See
## docs/llm-play-overhaul.md. Entity NAMES are pending the entity-identity RE
## (piece B); until then kind="npc" / name unknown, but relative position alone
## already removes the coordinate crutch.
import
  std/[strformat, strutils, algorithm, math, tables],
  ../decompbound/[snesbus, policy],
  ./touch_grass

const
  # Entity IDENTITY (RE'd 2026-07-16, see docs/memory-map.md + probe_entity_names.nim):
  # $2CD6 = sprite-group ID (the "who"); when $FFFF, fall back to $29CA sprite ptr.
  SpriteGroupBase = 0x2CD6
  SpritePtrBase   = 0x29CA
  # Known named characters. Appearance keys — same-looking townies share a group.
  GroupNames = {0x0091: "mom", 0x002C: "pokey", 0x01B5: "ness"}.toTable
  PtrNames   = {0x2A8A: "mom", 0x204B: "pokey", 0x4796: "ness"}.toTable

proc entityName(snes: SnesBus, slot: int): string =
  ## Name for a slot from its sprite-group / ptr identity ("" if unknown).
  let i = slot * SlotIndexStride
  let g = readU16(snes, SpriteGroupBase + i)
  if g != 0xFFFF and GroupNames.hasKey(g): return GroupNames[g]
  let p = readU16(snes, SpritePtrBase + i)
  if PtrNames.hasKey(p): return PtrNames[p]
  ""

type
  SceneEntity* = object
    slot*: int
    x*, y*: int
    dir*: string        # compass from player: N/S/E/W/NE/... or "here"
    distTiles*: int
    kind*: string       # "npc"
    name*: string       # identity name from $2CD6/$29CA, "" if unknown

  Scene* = object
    px*, py*: int
    room*: string
    ents*: seq[SceneEntity]
    text*: string       # on-screen dialogue, if any

proc compass(dx, dy: int): string =
  ## EB world coords: +x = east (right), +y = south (down). 8-way with a small
  ## dead zone so an entity right on top of the player reads "here".
  const dz = 6
  var s = ""
  if dy < -dz: s.add "N"
  elif dy > dz: s.add "S"
  if dx > dz: s.add "E"
  elif dx < -dz: s.add "W"
  if s.len == 0: "here" else: s

const
  VisibleTiles* = 40   # ~a screen + margin (256x224px ≈ 32x28 tiles); beyond
                       # this an entity is off-screen or a stale/other-area slot
  MaxNearby* = 8       # cap the list — this is "what's around me", not a census

proc buildScene*(snes: SnesBus): Scene =
  let pidx = PlayerSlot * SlotIndexStride
  result.px = readU16(snes, WorldXBase + pidx)
  result.py = readU16(snes, WorldYBase + pidx)
  for s in 0..24:
    if s == PlayerSlot: continue
    let i = s * SlotIndexStride
    let x = readU16(snes, WorldXBase + i)
    let y = readU16(snes, WorldYBase + i)
    if (x == 0 and y == 0) or x == 0xFFFF: continue
    let dx = x - result.px
    let dy = y - result.py
    let dist = (abs(dx) + abs(dy)) div 8
    if dist > VisibleTiles: continue   # off-screen / stale slot — not "nearby"
    result.ents.add SceneEntity(
      slot: s, x: x, y: y,
      dir: compass(dx, dy),
      distTiles: dist,
      kind: "npc",
      name: entityName(snes, s))
  result.ents.sort(proc(a, b: SceneEntity): int = cmp(a.distTiles, b.distTiles))
  if result.ents.len > MaxNearby: result.ents.setLen(MaxNearby)
  result.room = touch_grass.currentRoomLabel(snes)
  result.text = policy.getDialogueText(snes).strip()

proc sceneJson*(snes: SnesBus): string =
  ## Compact JSON for the LLM prompt. Nearest entities first.
  let sc = buildScene(snes)
  var parts: seq[string]
  for e in sc.ents:
    let nameField = if e.name.len > 0: &""","name":"{e.name}"""" else: ""
    parts.add &"""{{"slot":{e.slot},"kind":"{e.kind}"{nameField},"dir":"{e.dir}","dist_tiles":{e.distTiles}}}"""
  let textEsc = sc.text.replace("\"", "'").replace("\n", " ").strip()
  &"""{{"player":{{"x":"0x{sc.px:04X}","y":"0x{sc.py:04X}","room":"{sc.room}"}},""" &
    &""""nearby_entities":[{parts.join(",")}],"on_screen_text":"{textEsc}"}}"""
