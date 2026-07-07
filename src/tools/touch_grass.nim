## Touch Grass milestone helpers for LLM agent: deterministic intro skill (Lua)
## + WalkToSkillLua (reactive walkTo) + touchGrassPercent metric (REAL player world pos).
## GROUND TRUTH: entity world X at WRAM $0B8E,X ; Y at $0BCA,X (X = slot*2).
## PLAYER = SLOT 24 (idx 0x30), NOT slot 0. Verified by live instruction trace:
##   the per-frame projection at $C04E15/$C04E1D (STA $0B8E,X / $0BCA,X) writes the
##   walking player's coords with X=0x30 (slot 24). Slot 28 = 2nd party member
##   (Paula, seen in slot9/slot91 Photo Man states). Slot 0 is the first map
##   NPC/object -- its coords sit near the player's room, which made it LOOK like
##   the player while it never moved (masqueraded as "movement is frozen headless":
##   the game walked fine; we watched furniture).
## Sector at $89CA.
## Values (slot-24, byte verified from bin/states/*.state):
##   title/cold: (0000,0000) -> 0
##   bedroom game_start: (1FB8,0452) -> 25
##   house interior slot2: (1E90,05F8) -> 75
##   battle slot1: (05C3,0945) -> 50
##   outside (Twoson, slot9/91): (057F,1B0F) -> 100
## Slot stride for pos index: 2 (word arrays); player slot: 24 (byte offset 0x30).
## HARD: battle (05C3,0945) must NOT return 25 or 100.
## Only edit this file per constraints. All magic + TODO per AGENTS.

import
  ../decompbound/snesbus

const
  SectorOff* = 0x89CA
  # Verified player/entity world position bases (WRAM). Indexed as $0B8E + (slot * 2)
  # because 65816 word arrays (ASL on slot for X index in asm, 30 entity slots).
  WorldXBase* = 0x0B8E
  WorldYBase* = 0x0BCA
  PlayerSlot* = 24  # party leader lives in slot 24 (traced: $C04E15 writes $0B8E,X with X=0x30)
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
  ## Keys STRICTLY on verified player world pos $0B8E,X / $0BCA,X (slot 24 = party
  ## leader, idx=slot*2=0x30) + sector $89CA.
  ## Captured slot-24 coords (from bin/states/*.state + live walk trace):
  ##   title/cold: (0x0000,0x0000) -> 0
  ##   naming/pre (small pos): -> 0 (prevents title->100 jump)
  ##   bedroom (game_start): (0x1FB8,0x0452) -> 25
  ##   inter/house (slot2): (0x1E90,0x05F8) -> 75
  ##   battle (slot1): (0x05C3,0x0945) -> 50
  ##   outside (slot9/91, Twoson): (0x057F,0x1B0F) -> 100
  ## Slot stride=2; player=slot 24.
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
  # TODO(magic): battle party pos varies per encounter; slot-24 capture is
  # (05C3,0945) so the Y floor is 0x0900 (old 0x0950 floor missed the real player).
  let isBattleBox = (px >= 0x0580 and px <= 0x0600 and py >= 0x0900 and py <= 0x09A0)
  let isBroadIndoor = (px >= 0x1D00 and px < 0x2100 and py <= 0x0C00)
  if (px != 0 or py != 0) and not isBattleBox and not isBroadIndoor:
    return 100

  # default intermediate progress or unknown (battle, credits, other indoors)
  return 50

const IntroSkillLua* = """
-- Read-driven IntroSkillLua: title splash (empty/garbage text) -> short Start edges + A (to reach menu + pick New/Start New Game) -> naming (relaxed detect on any content or time: accept defaults with A + "Dont care"/OK dirs) x6 -> bedroom stop.
-- Branches + logs every screen.text() change and decisions. Does not depend solely on "New" match (decode often garbage even on visible menus per tests).
-- Stop using bedroom pos (emulates currentRoomLabel/touchGrass != title + bedroom).
-- Bounded, short edges only. See policy.nim screen.text/pad/frame/mem. Per AGENTS: magic bytes/offsets have TODO+comments.
local MAXF = 4500
local _intro = {
  last_txt = "",
  stage = "boot",
  last_change_f = 0,
  naming_steps = 0,
  action_count = 0
}

function update()
  local f = frame()
  if f > MAXF then return end

  local txt = screen.text() or ""
  local low = txt:lower()

  if txt ~= _intro.last_txt then
    print("Intro[f=" .. f .. " stage=" .. _intro.stage .. "]: screen.text=[" .. txt:gsub("\n", "\\n") .. "]")
    _intro.last_txt = txt
    _intro.last_change_f = f
  end

  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local sector = mem.read(0x89CA) + 256 * mem.read(0x89CB)

  -- STOP at bedroom (tg=25) or progressed in-game (read pos, per currentRoomLabel logic)
  -- TODO(magic): bedroom box + title guard copied from touchGrassPercent in this file; verified from captures.
  local in_bedroom = (px >= 0x1F00 and px < 0x2000 and py <= 0x0600) or
                     (math.abs(px - 0x1F40) <= 0x80 and math.abs(py - 0x05C0) <= 0x80)
  local is_titleish = (px == 0 and py == 0) or (px < 0x0100 and py < 0x0100)
  if in_bedroom then
    print("Intro: BEDROOM reached pos=" .. px .. "," .. py .. " sec=" .. sector .. " @f=" .. f .. " -> STOP")
    return
  end
  if not is_titleish and f > 300 and _intro.naming_steps >= 2 then
    print("Intro: left title (pos non-zero) @f=" .. f .. " -> STOP")
    return
  end

  -- 1. screen.text() empty/garbage (title splash or attract demo): press Start as short edges (gaps between) to reach the menu.
  if txt == "" or low:len() < 5 or (not low:find("new") and not low:find("dont") and not low:find("start") and not low:find("game")) then
    _intro.stage = "title"
    if (f == 220 or f == 221 or f == 222) then
      pad.press("Start")
      print("Intro: empty/garbage -> Start edge @f=" .. f)
      return
    end
    if f >= 260 and f < 1500 then
      if (f % 3 == 0) then pad.press("A") end
      if (f % 8 == 0) then pad.press("Down") end
      if (f % 17 == 0) then pad.press("Down") end
      if (f % 29 == 0) then pad.press("Right") end
      return
    end
    if f >= 1500 then
      if (f % 4 == 0) then pad.press("Down") end
      if (f % 11 == 0) then pad.press("A") end
    end
    return
  end

  -- 2. text contains "New" (New Game menu): navigate to + confirm New Game.
  if low:find("new") then
    _intro.stage = "newmenu"
    print("Intro: NEW GAME menu (contains New) @f=" .. f .. " -> nav + confirm")
    if (f % 5 == 0) then pad.press("Up") end
    if (f % 3 == 0) then pad.press("A") end
    if (f % 19 == 0) then pad.press("Down") end
    return
  end

  -- 3. a naming screen (name prompt / "Dont care" / keyboard visible in the text): accept the DEFAULT name (select the preset/OK/"Dont care" option, or the confirm sequence) — repeat through all 6.
  if low:find("dont care") or low:find("dont") or low:find("name") or low:find("ok") or low:len() > 6 then
    _intro.stage = "naming"
    print("Intro: NAMING (prompt/Dont care/keyboard) step~" .. _intro.naming_steps .. " @f=" .. f .. " -> accept default")
    if low:find("dont") then
      if (f % 8 == 0) then pad.press("Down") end
    end
    if (f % 3 == 0) then pad.press("A") end
    if (f % 11 == 0) then pad.press("Right") end
    if (f % 23 == 0) then pad.press("Down") end
    if f - _intro.last_change_f > 25 then
      _intro.naming_steps = _intro.naming_steps + 1
      _intro.last_change_f = f
      print("Intro: naming step advanced -> " .. _intro.naming_steps)
    end
    return
  end

  -- 4. when currentRoomLabel(snes) != "title" / touch_grass shows the bedroom (in-game): STOP. (already checked above via pos)
  if low:len() > 2 then
    if (f % 5 == 0) then pad.press("A") end
  end
end
"""

const WalkToSkillLua* = """
-- Reactive walkTo(tx, ty) skill for the LLM agent (touch-grass walk-out and general nav).
-- REACTIVE pathfinding only: no collision map / tile reader used (exact pass bit in tile word at 0x2640 unpinned per decompilation.md).
-- Reads live player (slot 24 = party leader) world pos every frame via mem.read: X at 0x0BBE/0x0BBF (LE), Y at 0x0BFA/0x0BFB.
-- Computes dominant direction (larger delta axis), presses that d-pad dir via pad.press.
-- DETECT STUCK: if pos unchanged for ~STUCK_N frames, switch to a perpendicular dir briefly to route around obstacle.
-- STOP: when manhattan dist <= THRESH. Robust + BOUNDED by MAXF frame cap from first target (never infinite-loops).
-- Usage (LLM includes this chunk then calls from its update() e.g. while not at door): walkTo(targetX, targetY)
-- TODO(magic): 0x0BBE/0x0BFA = WorldXBase/WorldYBase + PlayerSlot(24)*2 (this file); see policy.nim for mem.read/pad/frame API.
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
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
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

const WinBattleSkillLua* = """
-- WinBattleSkillLua: read-driven win via screen.text() (milestone 2c payoff).
-- Reads screen.text() each frame; decides based on visible menu/dialogue/battle text
-- instead of blind A-mash + mem heuristics alone.
-- Command menu ( "Bash"/"Goods"/"PSI"/"Defend" or "INPUT YOUR COMMAND" ): A for default Bash (top option).
-- Target selection (enemy visible): A to pick first.
-- Battle text/anim (damage nums, SMAAAASH lines etc): A to advance.
-- Victory: text contains "won"/"EXP"/"LEVEL UP" (or left battle box) -> stop.
-- Always logs screen.text() at decision points. Bounded by MAXF; robust exit via pos.
-- Expose: winBattle(); call from update() e.g. function update() winBattle() end
-- Sandbox: frame(), mem.read, pad.press, screen.text(). See policy.nim.
-- TODO(magic): BATTLE_BOX_* + pos bases from slot1 captures + touchGrassPercent; use for robust exit only.
local MAXF = 3600
local BATTLE_X1 = 0x0580
local BATTLE_X2 = 0x0600
local BATTLE_Y1 = 0x0900
local BATTLE_Y2 = 0x09A0

local _wb = {
  startf = nil,
  last_txt = "",
  no_prog = 0,
  last_f = 0
}

function winBattle()
  local f = frame()
  if not _wb.startf then
    _wb.startf = f
    _wb.last_f = f
  end
  if f - _wb.startf > MAXF then
    print("winBattle: MAXF cap reached; stopping")
    return
  end

  local txt = screen.text() or ""
  local low = txt:lower()

  -- log on text change for debug (what the read API actually sees)
  if txt ~= _wb.last_txt then
    print("winBattle[f=" .. f .. "]: screen.text=[" .. (txt:gsub("\n", "\\n")) .. "]")
    _wb.last_txt = txt
    _wb.no_prog = 0
    _wb.last_f = f
  else
    _wb.no_prog = _wb.no_prog + 1
  end

  -- victory / end detection via text (the point of reading)
  if low:find("won") or low:find("exp") or low:find("level up") or low:find("you won") then
    print("winBattle: VICTORY/EXP detected in screen.text -> stop")
    return
  end

  -- robust exit: left battle box (pos from slot1 capture) sustained
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local in_box = (px >= BATTLE_X1 and px <= BATTLE_X2 and py >= BATTLE_Y1 and py <= BATTLE_Y2)
  if not in_box and _wb.no_prog > 30 then
    print("winBattle: exited battle box (pos outside) -> stop")
    return
  end

  -- COMMAND MENU: read the options; default/first is Bash -> just A to select/confirm
  if txt:find("Bash") or txt:find("Goods") or txt:find("PSI") or txt:find("Defend") or txt:find("INPUT YOUR COMMAND") then
    print("winBattle: COMMAND MENU (read via screen.text) -> A for Bash")
    if (f % 3) == 0 then
      pad.press("A")
    end
    return
  end

  -- TARGET SELECTION (enemy list shown): A to target first/confirm
  -- (enemy names or target prompt may appear; fallback on visible non-command text)
  if txt:find("to the") or txt:find("which") or (not txt:find("Bash") and txt:len() > 3 and in_box) then
    print("winBattle: TARGET/ENEMY (read) -> A")
    if (f % 4) == 0 then
      pad.press("A")
    end
    return
  end

  -- BATTLE TEXT / ANIMATION / damage / SMAAAASH / numbers / results: A to advance
  if low:find("smash") or low:find("damage") or txt:find("%d%d") or low:find("hp") or txt:len() > 2 then
    if (f % 4) == 0 then
      pad.press("A")
    end
    return
  end

  -- default safe advance (text may be empty or undecoded in current decode; bounded presses)
  if (f % 5) == 0 then
    pad.press("A")
  end
end
"""

proc currentRoomLabel*(snes: SnesBus): string =
  ## Human label for the LLM summary (bedroom / outside / title etc).
  let pct = touchGrassPercent(snes)
  if pct == 0: return "title"
  if pct == 25: return "bedroom"
  if pct < 100: return "house_interior"
  return "outside_onett"
