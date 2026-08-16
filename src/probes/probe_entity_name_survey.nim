## Survey per-slot entity identity across named LLM fixture states.
##
## Method matches `probe_entity_names.nim`: WRAM `$2CD6` sprite-group (word ×
## slots, stride 2) plus companion `$29CA` sprite-data pointer. Player is slot
## 24. Slot 0 can be furniture — dump it, do not assume a name.
##
## Missing fixture files are skipped. No ROM bytes or state payloads are
## written; this prints ids, slots, and coordinates only.
import
  std/[strformat, strutils, os, tables, algorithm, sequtils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/touch_grass

type
  Sighting = object
    state: string
    slot: int
    x, y: int
    dist: int

const
  States = [
    "bin/states/llm/frank_arcade.state",
    "bin/states/llm/frank_downtown.state",
    "bin/states/llm/frank_corridor.state",
    "bin/states/llm/captain_approach.state",
    "bin/states/llm/captain_west.state",
    "bin/states/llm/buzz_meteor.state",
    "bin/states/llm/home_downstairs_night.state",
    "bin/states/llm/pokey_free.state",
    "bin/states/llm/pokey_done.state",
    "bin/states/llm/fourside60_from_paula.state",
    "bin/states/llm/fourside80_from_paula.state",
    "bin/states/llm/poo_joined.state",
    "bin/states/llm/onett_start.state",
  ]
  MaxSlot = 28
  EntitySpriteGroupBase = 0x2CD6
  EntitySpritePtrBase = 0x29CA
  EntityCollisionTypeBase = 0x2B6E
  PartyRosterBase = 0x988B
  SpriteGroupMom = 0x0091
  SpriteGroupPokey = 0x002C
  SpriteGroupNess = 0x01B5
  SpritePtrMom = 0x2A8A
  SpritePtrPokey = 0x204B
  SpritePtrNess = 0x4796

proc slotPos(snes: SnesBus, s: int): (int, int) =
  ## Read world X/Y for entity slot s.
  let i = s * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc isActive(snes: SnesBus, s: int): bool =
  ## A slot is active if it has a real position (not empty 0,0 and not FFFF).
  let (x, y) = slotPos(snes, s)
  not ((x == 0 and y == 0) or x == 0xFFFF or y == 0xFFFF)

proc loadState(snes: SnesBus, c: var Cpu, path: string) =
  ## Deserialize a save-state into the bus/CPU.
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)

proc spriteGroup(snes: SnesBus, s: int): int =
  ## Read `$2CD6 + slot*2` sprite-group index.
  readU16(snes, EntitySpriteGroupBase + s * SlotIndexStride)

proc spritePtr(snes: SnesBus, s: int): int =
  ## Read `$29CA + slot*2` live sprite-data pointer.
  readU16(snes, EntitySpritePtrBase + s * SlotIndexStride)

proc collisionType(snes: SnesBus, s: int): int =
  ## Read `$2B6E + slot*2` collision-type (hitbox shape, not identity).
  readU16(snes, EntityCollisionTypeBase + s * SlotIndexStride)

proc knownHint(g, p: int, slot: int): string =
  ## Tag already-verified Mom/Pokey/Ness ids; empty otherwise.
  if slot == PlayerSlot:
    return "player"
  if g == SpriteGroupMom or p == SpritePtrMom:
    return "mom?"
  if g == SpriteGroupPokey or p == SpritePtrPokey:
    return "pokey?"
  if g == SpriteGroupNess or p == SpritePtrNess:
    return "ness?"
  ""

proc idKey(g, p: int): string =
  ## Stable (group, ptr) key for the cross-state index.
  &"g=0x{g:04X}/p=0x{p:04X}"

proc manhattan(ax, ay, bx, by: int): int =
  ## Manhattan pixel distance between two world points.
  abs(ax - bx) + abs(ay - by)

let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
var c = snes.resetCpu()

echo "Entity identity survey"
echo "  $2CD6 sprite-group  $29CA sprite-ptr  $2B6E collision-type"
echo "  player = slot 24; slot 0 may be furniture"
echo ""

var
  index = initTable[string, seq[Sighting]]()
  loaded: seq[string]
  missing: seq[string]

for st in States:
  if not fileExists(st):
    echo &"MISSING {st}"
    missing.add extractFilename(st)
    continue
  loadState(snes, c, st)
  loaded.add extractFilename(st)
  let (px, py) = slotPos(snes, PlayerSlot)
  let r0 = readU8(snes, PartyRosterBase)
  let r1 = readU8(snes, PartyRosterBase + 1)
  let r2 = readU8(snes, PartyRosterBase + 2)
  let r3 = readU8(snes, PartyRosterBase + 3)
  echo &"======== {extractFilename(st)}  player=(0x{px:04X},0x{py:04X}) party={r0},{r1},{r2},{r3} ========"
  echo "  slot  group($2CD6)  ptr($29CA)  ctype($2B6E)  pos                  dist  hint"
  for s in 0..MaxSlot:
    if not isActive(snes, s):
      continue
    let g = spriteGroup(snes, s)
    let p = spritePtr(snes, s)
    let ct = collisionType(snes, s)
    let (x, y) = slotPos(snes, s)
    let d = manhattan(x, y, px, py)
    let hint = knownHint(g, p, s)
    let tag = if s == PlayerSlot: "P" else: " "
    echo &"  {tag}{s:2}   0x{g:04X}         0x{p:04X}       0x{ct:04X}         (0x{x:04X},0x{y:04X})  {d:5}  {hint}"
    let key = idKey(g, p)
    if not index.hasKey(key):
      index[key] = @[]
    index[key].add Sighting(state: extractFilename(st), slot: s, x: x, y: y, dist: d)
  echo ""

echo "======== CROSS-STATE INDEX (group, ptr) ========"
var keys = toSeq(index.keys)
keys.sort()
for key in keys:
  let rows = index[key]
  var states: seq[string]
  for row in rows:
    if row.state notin states:
      states.add row.state
  echo &"{key}  states={states.len}  sightings={rows.len}"
  for row in rows:
    echo &"    {row.state:32} slot={row.slot:2}  pos=(0x{row.x:04X},0x{row.y:04X})  dist={row.dist}"

echo ""
echo "======== SUMMARY ========"
echo &"loaded={loaded.len} missing={missing.len}"
if missing.len > 0:
  echo "missing: ", missing.join(", ")
echo "loaded: ", loaded.join(", ")
