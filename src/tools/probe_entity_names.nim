## Print per-slot entity identity for known LLM states.
##
## Identity field (verified 2026-07-16): WRAM `$2CD6` = sprite-group index
## (word × slots, stride 2). Written at entity spawn `$C0200B` from DP `$2B`.
## Indexes ROM sprite-pointer table `$EF133F` (4-byte entries, bank `$EF`).
## Companion `$29CA` = sprite data pointer (table[id] + 9); stays valid even when
## `$2CD6` reads `$FFFF` on some leftover/active slots.
##
## Ground truth cross-check:
##   home_door slot 4          == Mom sprite group `$0091`
##   home_downstairs_night     Mom among indoor slots also `$0091`
##   pokey_free nearest (slot0) == Pokey `$002C` (≠ Mom)
import
  std/[strformat, strutils, os, tables, sequtils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ./touch_grass

const
  States = [
    "bin/states/llm/pokey_free.state",
    "bin/states/llm/home_door.state",
    "bin/states/llm/home_downstairs_night.state",
    "bin/states/llm/onett_start.state",
  ]
  MaxSlot = 28
  # Entity sprite-group ID array (WRAM). See docs/memory-map.md.
  EntitySpriteGroupBase = 0x2CD6
  # Live sprite-data pointer (table[group] + 9). Fallback when group is FFFF.
  EntitySpritePtrBase = 0x29CA
  # Verified group IDs from cross-state diff (not from external docs).
  SpriteGroupMom = 0x0091
  SpriteGroupPokey = 0x002C
  SpriteGroupNess = 0x01B5
  # Matching sprite-pointer values (stable even when group reads FFFF).
  SpritePtrMom = 0x2A8A
  SpritePtrPokey = 0x204B
  SpritePtrNess = 0x4796
  DoorSlot = 4
  PokeyNearestSlot = 0

proc slotPos(snes: SnesBus, s: int): (int, int) =
  ## Read world X/Y for entity slot s.
  let i = s * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc isActive(snes: SnesBus, s: int): bool =
  ## A slot is active if it has a real position (not empty 0,0 and not FFFF).
  let (x, y) = slotPos(snes, s)
  not ((x == 0 and y == 0) or x == 0xFFFF)

proc loadState(snes: SnesBus, c: var Cpu, path: string) =
  ## Deserialize a save-state into the bus/CPU.
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)

proc spriteGroup(snes: SnesBus, s: int): int =
  ## Read `$2CD6 + slot*2` sprite-group index.
  readU16(snes, EntitySpriteGroupBase + s * SlotIndexStride)

proc spritePtr(snes: SnesBus, s: int): int =
  ## Read `$29CA + slot*2` live sprite-data pointer.
  readU16(snes, EntitySpritePtrBase + s * SlotIndexStride)

proc identityValue(snes: SnesBus, s: int): int =
  ## Prefer sprite-group ID; fall back to sprite pointer when group is cleared.
  let g = spriteGroup(snes, s)
  if g != 0 and g != 0xFFFF:
    return g
  spritePtr(snes, s)

proc inferredName(snes: SnesBus, s: int): string =
  ## Map verified sprite-group / pointer values to a short name.
  if s == PlayerSlot:
    return "Ness"
  let g = spriteGroup(snes, s)
  let p = spritePtr(snes, s)
  if g == SpriteGroupMom or p == SpritePtrMom:
    return "Mom"
  if g == SpriteGroupPokey or p == SpritePtrPokey:
    return "Pokey"
  if g == SpriteGroupNess or p == SpritePtrNess:
    return "Ness"
  if g != 0 and g != 0xFFFF:
    return &"sprite_{g:04X}"
  if p != 0:
    return &"ptr_{p:04X}"
  "unknown"

let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
var c = snes.resetCpu()

echo "Entity identity = WRAM $2CD6 (sprite group, stride 2)"
echo "Fallback / companion = WRAM $29CA (sprite ptr = table[group]+9)"
echo "Known: Mom=$0091/ptr$2A8A  Pokey=$002C/ptr$204B  Ness=$01B5/ptr$4796"
echo ""

var doorId = -1
var momIds: seq[int]
var pokeyId = -1

for st in States:
  if not fileExists(st):
    echo &"MISSING {st}"
    continue
  loadState(snes, c, st)
  let (px, py) = slotPos(snes, PlayerSlot)
  echo &"======== {extractFilename(st)}  player=(0x{px:04X},0x{py:04X}) ========"
  echo "  slot -> group($2CD6) -> ptr($29CA) -> identity -> name"
  for s in 0..MaxSlot:
    if not isActive(snes, s):
      continue
    let g = spriteGroup(snes, s)
    let p = spritePtr(snes, s)
    let id = identityValue(snes, s)
    let name = inferredName(snes, s)
    let (x, y) = slotPos(snes, s)
    let tag = if s == PlayerSlot: "P " else: "  "
    echo &"  {tag}slot {s:2}  group=0x{g:04X}  ptr=0x{p:04X}  id=0x{id:04X}  -> {name:12}  pos=(0x{x:04X},0x{y:04X})"
    if st.endsWith("home_door.state") and s == DoorSlot:
      doorId = id
    if st.endsWith("home_downstairs_night.state") and name == "Mom":
      momIds.add id
    if st.endsWith("pokey_free.state") and s == PokeyNearestSlot:
      pokeyId = id
  echo ""

echo "======== VERIFICATION ========"
echo &"home_door slot {DoorSlot} identity     = 0x{doorId:04X}"
let momIdStr = momIds.mapIt("0x" & it.toHex(4)).join(", ")
echo &"home_downstairs_night Mom id(s) = {momIdStr}"
echo &"pokey_free slot {PokeyNearestSlot} (nearest)   = 0x{pokeyId:04X}"
let doorMatchesMom = doorId >= 0 and momIds.anyIt(it == doorId)
let doorDiffersPokey = doorId >= 0 and pokeyId >= 0 and doorId != pokeyId
echo &"door == Mom?     {doorMatchesMom}"
echo &"door != Pokey?   {doorDiffersPokey}"
if doorMatchesMom and doorDiffersPokey:
  echo "PASS: door blocker shares Mom's identity and differs from Pokey."
else:
  echo "FAIL: expected door==Mom and door!=Pokey."
