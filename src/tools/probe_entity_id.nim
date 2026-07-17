## Discover a per-slot ENTITY IDENTITY field in WRAM (who is this NPC?).
##
## We have position ($0B8E/$0BCA) and collision-type ($2B6E, hitbox shape only)
## but NO verified "which NPC" field. This probe auto-scans the object-array
## region for slot-structured word arrays (uniform on empty slots, ≥2 distinct
## values across active slots) and prints per-slot values across states whose
## cast we KNOW, so we can pin the identity array by cross-referencing:
##   pokey_free            -> Pokey stands next to Ness at the meteor
##   home_downstairs_night -> Mom + Tracy present (slots ~3-9)
##   home_door             -> the mystery door NPC ("[redacted dialogue]")
## If the door NPC's identity value == Mom's value in the downstairs state, the
## "cop" label was wrong. If it matches nothing / a distinct cop sprite, note it.
import
  std/[strformat, tables, algorithm, sequtils, os, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ./touch_grass

const
  States = [
    "bin/states/llm/pokey_free.state",
    "bin/states/llm/home_door.state",
    "bin/states/llm/home_downstairs_night.state",
    "bin/states/llm/onett_start.state",
  ]
  MaxSlot = 28
  # Scan windows around the known object arrays ($0B8E X, $0BCA Y, $2B6E ctype).
  ScanLo = [0x0B00, 0x2A00]
  ScanHi = [0x1000, 0x2C00]

proc slotPos(snes: SnesBus, s: int): (int, int) =
  let i = s * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc activeSlots(snes: SnesBus): seq[int] =
  ## A slot is "active" if it has a real position (not empty 0,0 and not FFFF).
  for s in 0..MaxSlot:
    let (x, y) = slotPos(snes, s)
    if (x == 0 and y == 0) or x == 0xFFFF: continue
    result.add s

proc loadState(snes: SnesBus, c: var Cpu, path: string) =
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)

let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
var c = snes.resetCpu()

# --- Pass 1: which slots are active + where, per state (identify NPCs by pos) ---
echo "==================== ACTIVE SLOTS PER STATE ===================="
for st in States:
  loadState(snes, c, st)
  let (ppx, ppy) = slotPos(snes, PlayerSlot)
  echo &"\n{st}  player(slot24)=(0x{ppx:04X},0x{ppy:04X})"
  for s in activeSlots(snes):
    if s == PlayerSlot: continue
    let (x, y) = slotPos(snes, s)
    echo &"  slot {s:2}: pos=(0x{x:04X},0x{y:04X})"

# --- Pass 2: auto-find slot-structured word arrays (candidate identity fields) ---
# Criteria: over slots 0..MaxSlot, empty slots share one sentinel value, and
# active slots carry >=2 distinct values (so the field DISTINGUISHES entities).
echo "\n==================== CANDIDATE IDENTITY ARRAYS ===================="
echo "(base : per-state list of active-slot values; want static + distinct)"

proc arrayVals(snes: SnesBus, base: int): seq[int] =
  for s in 0..MaxSlot: result.add readU16(snes, base + s * SlotIndexStride)

for w in 0..<ScanLo.len:
  var base = ScanLo[w]
  while base < ScanHi[w]:
    # Evaluate against the FIRST state that has >=2 active non-player NPCs.
    var chosen = ""
    var ok = false
    for st in States:
      loadState(snes, c, st)
      let act = activeSlots(snes).filterIt(it != PlayerSlot)
      if act.len < 2: continue
      let vals = arrayVals(snes, base)
      # empty-slot uniformity
      var emptyVals: seq[int]
      for s in 0..MaxSlot:
        let (x, y) = slotPos(snes, s)
        if (x == 0 and y == 0) or x == 0xFFFF: emptyVals.add vals[s]
      let emptyUniform = emptyVals.len == 0 or emptyVals.allIt(it == emptyVals[0])
      # active distinctness (ignore the empty sentinel)
      let sentinel = if emptyVals.len > 0: emptyVals[0] else: -1
      var actVals: seq[int]
      for s in act: actVals.add vals[s]
      let distinct2 = actVals.deduplicate.filterIt(it != sentinel).len >= 2
      if emptyUniform and distinct2:
        ok = true
        chosen = st
      break
    if ok:
      # Print this candidate's active-slot values across ALL states.
      var line = &"  base=0x{base:04X}:"
      for st in States:
        loadState(snes, c, st)
        let vals = arrayVals(snes, base)
        var parts: seq[string]
        for s in activeSlots(snes):
          if s == PlayerSlot:
            parts.add &"P=0x{vals[s]:04X}"
          else:
            parts.add &"{s}=0x{vals[s]:04X}"
        line.add &"\n      {extractFilename(st):28} [{parts.join(\" \")}]"
      echo line
    base += 2

echo "\ndone"
