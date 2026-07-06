## Touch Grass milestone helpers for LLM agent: deterministic intro skill (Lua)
## + WalkToSkillLua (reactive walkTo) + touchGrassPercent metric (REAL player world pos).
## GROUND TRUTH: entity world X at WRAM $0B8E,X ; Y at $0BCA,X (X = slot*2).
## Player = first active entity, slot 0 (idx=0). 81 LDA/STA $0B8E,X sites in ROM confirm.
## Sector at $89CA. Captured via trace_tool + stepper equivalent to --load-srm --watch 0B8E-0BCC,89CA
##   + IntroSkillLua sequence (auto-advance scripted A/Start/Down/Right).
## Values (byte verified in bus.mem):
##   title: (0000,0000) sec 0000 -> 0
##   bedroom (post naming): (1F40,05C0) sec 0000/FFFF -> 25
##   inter (slot2 proxy / house): (1E68,05C0) sec FFFF -> 50/75
##   outside: region not matching bedroom/inter/title (when nonzero pos outside those boxes)
## Slot stride for pos index: 2 (word arrays); player slot: 0.
## HARD: slot1 battle (05C0,0970) sec FFFF must NOT return 25 or 100.
## Only edit this file per constraints. All magic + TODO per AGENTS.

import
  ../decompbound/snesbus

const
  SectorOff* = 0x89CA
  # Verified player/entity world position bases (WRAM). Indexed as $0B8E + (slot * 2)
  # because 65816 word arrays (ASL on slot for X index in asm, 30 entity slots).
  WorldXBase* = 0x0B8E
  WorldYBase* = 0x0BCA
  PlayerSlot* = 0   # first active entity is player (slot 0)
  SlotIndexStride* = 2  # bytes per slot for these parallel word arrays
  # legacy heuristic offsets (kept for ref; not used in fixed metric)
  PosXOff* = 0x00B4
  PosYOff* = 0x00B6
  MenuFlagOff* = 0x0024

proc readU8*(snes: SnesBus, off: int): int =
  ## Read WRAM byte at 7E:off (or full if >0xFFFF). Used by metric.
  let ea = if off > 0xFFFF: off else: 0x7E0000 + off
  if ea >= 0 and ea < snes.bus.mem.len:
    return snes.bus.mem[ea].int
  0

proc readU16*(snes: SnesBus, off: int): int =
  ## Read WRAM u16 LE at off.
  let lo = readU8(snes, off)
  let hi = readU8(snes, off + 1)
  lo or (hi shl 8)

proc touchGrassPercent*(snes: SnesBus): int =
  ## 0 at title/pre-game/naming (cold or small pos), 25 bedroom, 75 house inter, 50 other indoors/battle, 100 ONLY real Onett overworld.
  ## Keys STRICTLY on verified player world pos $0B8E,X / $0BCA,X (slot 0, idx=slot*2)
  ## + sector $89CA.
  ## Captured coords (via stepper + loadState + llm_ai repro runs + pos logs):
  ##   title/cold: (0x0000,0x0000) sec 0x0000 -> 0
  ##   naming/pre (small pos, e.g. 0x0005,0x0028 or 0xFFFB): -> 0 (prevents title->100 jump)
  ##   bedroom (post naming): (0x1F40,0x05C0) sec 0/FFFF -> 25
  ##   inter/house (slot2): (0x1E68,0x05C0) sec FFFF -> 75
  ##   battle (slot1): (0x05C0,0x0970) sec FFFF -> 50
  ##   credit screen false (1D48,0B30): -> 50 (now guarded)
  ##   outside: only when pos escapes broad indoor band AND not pre/small/battle (real Onett validated visually as non-naming/credit)
  ## Slot stride=2; player=slot 0.
  ## All magic accompanied by TODO/comments per AGENTS.
  let sector = readU16(snes, SectorOff)
  let idx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + idx)
  let py = readU16(snes, WorldYBase + idx)

  # Title / cold boot / pre-placement (naming): zero or small pos.
  # Prevents jump title->100 on early nonzero garbage/small during naming (visual: naming menu).
  # TODO: magic small-pos threshold guards pre-bedroom states; 0x0100 chosen from captured naming ~0005 vs bedroom 1F40.
  if (px == 0 and py == 0) or (px < 0x0100 and py < 0x0100):
    return 0

  # Bedroom (Ness room, game start post-naming). Exact + tight region from capture.
  # (0x1F40,0x05C0) observed at f~832 in pos logs.
  # TODO: the exact (X,Y) is the placed player coord in bedroom map; range tolerates minor variance.
  if (px >= 0x1F00 and px < 0x2000 and py <= 0x0600) or
     (abs(px - 0x1F40) <= 0x80 and abs(py - 0x05C0) <= 0x80):
    return 25

  # Intermediates (stairs, hall, downstairs, door inside house).
  # Captured proxy (0x1E68,0x05C0) from slot2 state (house-area snapshot).
  # TODO: pin exact per-room coords via more trace+input runs when outside script works.
  if (px >= 0x1E00 and px < 0x1F00 and py <= 0x0600):
    return 75

  # Outside Onett (first step out, touch grass = 100).
  # TIGHTENED: require genuine escape from broad indoor/house region (1D00-20FF, Y<=0C00 covers bedroom/inter/credits).
  # Also exclude small pre, battle box. Must be nonzero world pos outside.
  # Visual ground truth: previous "100" states were naming menu or credits screen, not Onett trees/streets.
  # Real outside will have pos outside this band (per Onett map placement).
  # TODO: replace with exact captured outside (Onett) (X,Y) + sector when traced from successful exit.
  let isBattleBox = (px >= 0x0580 and px <= 0x0600 and py >= 0x0950 and py <= 0x09A0)
  let isBroadIndoor = (px >= 0x1D00 and px < 0x2100 and py <= 0x0C00)
  if (px != 0 or py != 0) and not isBattleBox and not isBroadIndoor:
    return 100

  # default intermediate progress or unknown (battle, credits, other indoors)
  return 50

const IntroSkillLua* = """
-- Deterministic intro skill: title -> new game -> naming (accept defaults via A-mash + dirs) -> Ness bedroom.
-- Lets agent start from gameplay; not the interesting part. Fixed sequence, frame based.
function update()
  local f = frame()
  if f < 180 then
    return
  end
  if f == 220 or f == 221 then
    pad.press('Start')
    return
  end
  if f >= 260 and f < 820 then
    -- A-mash + occasional dir for letter select / confirm on naming (Ness default + OK).
    -- Standard fixed sequence that reaches bedroom on this harness.
    if f % 3 == 0 then
      pad.press('A')
    end
    if f % 17 == 0 then
      pad.press('Down')
    end
    if f % 29 == 0 then
      pad.press('Right')
    end
    return
  end
  if f >= 900 then
    -- In bedroom (or house entry): walk down + A to clear any text, head for stairs/door.
    if f % 4 == 0 then
      pad.press('Down')
    end
    if f % 11 == 0 then
      pad.press('A')
    end
  end
end
"""

const WalkToSkillLua* = """
-- Reactive walkTo(tx, ty) skill for the LLM agent (touch-grass walk-out and general nav).
-- REACTIVE pathfinding only: no collision map / tile reader used (exact pass bit in tile word at 0x2640 unpinned per decompilation.md).
-- Reads live player (slot 0) world pos every frame via mem.read: X at 0x0B8E/0x0B8F (LE), Y at 0x0BCA/0x0BCB.
-- Computes dominant direction (larger delta axis), presses that d-pad dir via pad.press.
-- DETECT STUCK: if pos unchanged for ~STUCK_N frames, switch to a perpendicular dir briefly to route around obstacle.
-- STOP: when manhattan dist <= THRESH. Robust + BOUNDED by MAXF frame cap from first target (never infinite-loops).
-- Usage (LLM includes this chunk then calls from its update() e.g. while not at door): walkTo(targetX, targetY)
-- TODO(magic): 0x0B8E etc are the byte-verified WRAM bases (WorldXBase/WorldYBase in this file); see policy.nim for mem.read/pad/frame API.
local THRESH = 12
local STUCK_N = 30
local MAXF = 12000
local _walk = {tx=nil, ty=nil, lx=nil, ly=nil, stuck=0, startf=nil}
function walkTo(tx, ty)
  local f = frame()
  if not _walk.startf or _walk.tx ~= tx or _walk.ty ~= ty then
    _walk.tx = tx
    _walk.ty = ty
    _walk.startf = f
    _walk.lx = nil
    _walk.ly = nil
    _walk.stuck = 0
  end
  if f - _walk.startf > MAXF then
    return
  end
  local px = mem.read(0x0B8E) + 256 * mem.read(0x0B8F)
  local py = mem.read(0x0BCA) + 256 * mem.read(0x0BCB)
  local dx = tx - px
  local dy = ty - py
  local adx, ady = math.abs(dx), math.abs(dy)
  if adx + ady <= THRESH then
    _walk.tx = nil
    _walk.ty = nil
    _walk.startf = nil
    return
  end
  if _walk.lx == px and _walk.ly == py then
    _walk.stuck = _walk.stuck + 1
  else
    _walk.stuck = 0
  end
  _walk.lx = px
  _walk.ly = py
  local dir
  local use_perp = (_walk.stuck > STUCK_N)
  if adx >= ady then
    dir = (dx > 0) and "Right" or "Left"
    if use_perp then
      dir = ((_walk.stuck // 20) % 2 == 0) and "Down" or "Up"
    end
  else
    dir = (dy > 0) and "Down" or "Up"
    if use_perp then
      dir = ((_walk.stuck // 20) % 2 == 0) and "Right" or "Left"
    end
  end
  pad.press(dir)
end
"""

proc currentRoomLabel*(snes: SnesBus): string =
  ## Human label for the LLM summary (bedroom / outside / title etc).
  let pct = touchGrassPercent(snes)
  if pct == 0: return "title"
  if pct == 25: return "bedroom"
  if pct < 100: return "house_interior"
  return "outside_onett"
