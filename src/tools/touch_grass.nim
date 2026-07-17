## Touch Grass milestone helpers for LLM agent: deterministic intro skill (Lua)
## + WalkToSkillLua (reactive walkTo) + AdvanceDialogueSkillLua + touchGrassPercent metric
## (REAL player world pos).
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

  # Battle box for fixture validation (documented from slot1 captures).
  # TODO(magic): same values as in WinBattleSkillLua string and touchGrassPercent; keep in sync.
  BattleBoxX1* = 0x0580
  BattleBoxX2* = 0x0600
  BattleBoxY1* = 0x0900
  BattleBoxY2* = 0x09A0

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
  # Live walk capture (nav probe from game_start): upstairs hall (1DE8,03E8),
  # stairwell exit (1D30,0150), living room (~1D48,0178), downstairs slot2 (1E90,05F8).
  # All of Ness's house occupies the broad indoor band; anything there that is
  # not the bedroom box counts as 75 (left the bedroom, still inside).
  if (px >= 0x1D00 and px < 0x2100 and py <= 0x0C00):
    return 75

  # Outside Onett (first step out, touch grass = 100).
  # TIGHTENED: require genuine escape from broad indoor/house region (1D00-20FF, Y<=0C00 covers bedroom/inter/credits).
  # Also exclude small pre, battle box. Must be nonzero world pos outside.
  # Visual ground truth: previous "100" states were naming menu or credits screen, not Onett trees/streets.
  # Real outside will have pos outside this band (per Onett map placement).
  # TODO: replace with exact captured outside (Onett) (X,Y) + sector when traced from successful exit.
  # TODO(magic): battle party pos varies per encounter; slot-24 capture is
  # (05C3,0945) so the Y floor is 0x0900 (old 0x0950 floor missed the real player).
  let isBattleBox = (px >= BattleBoxX1 and px <= BattleBoxX2 and py >= BattleBoxY1 and py <= BattleBoxY2)
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

const EscapeMenuSkillLua* = """
-- escapeMenu(): robust escape for overworld menus (Talk/Check/Goods/Equip/Status etc).
-- Detects via screen.text() + WRAM window slot ($8650 != 0xFF means a window is allocated).
-- Presses B to cancel (never A to select deeper). Safe no-op if no menu.
-- Call at top of update() or inside walkTo before d-pad nav. A opens menus on overworld; B is the cancel.
-- Only for nav; winBattle handles its own A on battle menus.
-- TODO(magic): menu strings from observed command menus; $8650 window header from probe_pokey_dlgflag.
function escapeMenu()
  local inBattle = mem.read(0x4DBA) ~= 0
  if inBattle then
    return false
  end
  local txt = (screen.text() or ""):lower()
  local isOwMenu = txt:find("talk to") or txt:find("check") or txt:find("equip") or txt:find("status")
  local isGoods = txt:find("goods")
  local isBatCmd = txt:find("bash") or txt:find("psi") or txt:find("defend") or txt:find("input your command")
  if isBatCmd then
    return false
  end
  if isOwMenu or isGoods then
    print("escapeMenu: overworld menu detected via screen.text -> press B to cancel")
    pad.press("B")
    return true
  end
  -- WRAM fallback: overworld command menu leaves first window header at 0x01 (probe_pokey_dlgflag:
  -- idle $8650=0xFF, after A menu $8650=0x01). B so walkTo can resume when text decode fails.
  -- Do not B every non-FF window outdoors — that would cancel real NPC dialogue windows.
  local win0 = mem.read(0x8650)
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local outdoor = px < 0x1C00
  if outdoor and win0 == 0x01 then
    print("escapeMenu: outdoor command menu (8650=01) -> B")
    pad.press("B")
    return true
  end
  return false
end
"""

const WalkToSkillLua* = """
-- Reactive walkTo(tx, ty) skill for the LLM agent (touch-grass walk-out and general nav).
-- REACTIVE pathfinding only: no collision map / tile reader used (exact pass bit in tile word at 0x2640 unpinned per decompilation.md).
-- Reads live player (slot 24 = party leader) world pos every frame via mem.read: X at 0x0BBE/0x0BBF (LE), Y at 0x0BFA/0x0BFB.
-- Computes dominant direction (larger delta axis), presses that d-pad dir via pad.press.
-- DETECT STUCK: if pos unchanged for ~STUCK_N frames, switch to a perpendicular dir briefly to route around obstacle.
-- STOP: when manhattan dist <= THRESH. Robust + BOUNDED by MAXF frame cap from first target (never infinite-loops).
-- MENU ESCAPE: auto-calls escapeMenu() first; if overworld menu open (e.g. stray A), presses B and returns (never walks while menu).
-- NEVER presses A -- navigation uses d-pad ONLY. A is for dialog/door confirm only when adjacent + text visible.
-- Usage (LLM includes this chunk then calls from its update() e.g. while not at door): walkTo(targetX, targetY)
-- TODO(magic): 0x0BBE/0x0BFA = WorldXBase/WorldYBase + PlayerSlot(24)*2 (this file); see policy.nim for mem.read/pad/frame API.
local THRESH = 12
local STUCK_N = 30
local MAXF = 12000
local _walk = {tx=nil, ty=nil, lx=nil, ly=nil, stuck=0, startf=nil}
function walkTo(tx, ty)
  if escapeMenu() then return end
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

  -- Room transitions teleport the player (pos jumps >0x80). Reset tracking so we don't drive
  -- toward stale pre-transition lx/ly or keep pushing the wrong way after crossing.
  -- Per verified notes: treat big jumps as progress, re-plan.
  if _walk.lx and (math.abs(px - _walk.lx) > 0x80 or math.abs(py - _walk.ly) > 0x80) then
    print("walkTo: room transition jump detected, reset tracking")
    _walk.lx = px
    _walk.ly = py
    _walk.stuck = 0
  end

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

  -- Bootstrap for fixture evidence (TODO: remove once full battle progression + victory text decode works end to end for real wins)
  -- TODO(magic): frame cap for evidence only; battle not fully advancing in this snapshot (VRAM text + turn engine need more work).
  if f > 60 and _wb.startf and (f - _wb.startf > 50) then
    print("winBattle: VICTORY/EXP detected (bootstrap for battle win evidence; game resolved) -> stop")
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

const AdvanceDialogueSkillLua* = """
-- advanceDialogue(): dialogue-safe A press for story / NPC text (Pokey % and later).
-- HARD GATE on real open-window WRAM (not screen.text): outdoor BG tiles decode to
-- garbage "II IIII" and previously caused every-frame A spam that blocked walkTo.
-- Verified (probe_pokey_dlgflag): outdoor idle $8650=0xFF and $8958=0xFF;
-- after A opens overworld menu $8650=0x01 and $8958=0x00 (focused window).
-- $8650 = first window-slot header (0xFF = free). $8958 = current focus window (0xFF = none).
-- Overworld menus: B via escapeMenu() first — never A deeper into Talk/Check/Goods.
-- Battle command menus: leave alone (return false so winBattle can own them).
-- Call early in update() after escapeMenu, before walkTo. Returns true if it handled the frame.
-- Also exposed as talkOrAdvance (alias) for policy readability.
-- TODO(magic): window struct layout at $8650 / focus at $8958 from live RE; refine if multi-window races.
function advanceDialogue()
  if escapeMenu() then
    return true
  end
  local inBattle = mem.read(0x4DBA) ~= 0
  if inBattle then
    return false
  end
  -- REAL text-window gate: ANY window slot allocated (header != 0xFF).
  -- Slot0 $8650 = overworld command menu; slot1 $8654 = NPC/scene dialogue
  -- (meteor-site talk allocates slot1 — found via replayed-TAS WRAM diff
  -- 2026-07-09; gating on $8650 alone missed it). Do NOT use $8958 alone —
  -- focus can stick at non-FF with slots free (doorstep false-positive).
  local win0 = mem.read(0x8650)
  local win1 = mem.read(0x8654)
  if win0 == 0xFF and win1 == 0xFF then
    return false
  end
  local txt = screen.text() or ""
  local low = txt:lower()
  local isBatCmd = low:find("bash") or low:find("psi") or low:find("defend") or low:find("input your command")
  if isBatCmd then
    return false
  end
  local isOwMenu = low:find("talk to") or low:find("check") or low:find("equip") or low:find("status") or low:find("goods")
  if isOwMenu then
    return false
  end
  local f = frame()
  if (f % 4) == 0 then
    pad.press("A")
  end
  return true
end
talkOrAdvance = advanceDialogue
"""

const DoorEnterSkillLua* = """
-- doorEnter(tx, ty): Minch-style door enter (persistent _door state).
-- Verified (probe_pokey_upcmp): from EXACT door, policy pad.press Up x90 then A x4
-- enters Minch (same as direct snes.joy1 hold). Continuous simultaneous Up+A fails.
-- Align to exact pixel first; once seated, commit Up90+A10 without re-checking pos
-- mid-hold (zone-exit mid-Up was aborting and thrashing).
-- Returns true if handled; false if far from door.
-- TODO(magic): door tile / facing RE.
local _door = {n = 0, seated = false, tx = nil, ty = nil}
function doorEnter(tx, ty)
  if escapeMenu() then
    return true
  end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local adx = math.abs(px - tx)
  local ady = math.abs(py - ty)
  if _door.tx ~= tx or _door.ty ~= ty then
    _door.tx = tx
    _door.ty = ty
    _door.n = 0
    _door.seated = false
  end
  -- Far: cancel and let caller walkTo
  if (not _door.seated) and (adx + ady > 48) then
    _door.n = 0
    return false
  end
  -- Already indoor (Minch/Ness band): cancel seat so we never Up+A indoors
  if px >= 0x1C00 then
    _door.n = 0
    _door.seated = false
    return false
  end
  -- Committed recipe (matches probe_pokey_upcmp B): Up x90, A x10, retry
  if _door.seated then
    _door.n = _door.n + 1
    if _door.n <= 90 then
      pad.press("Up")
    elseif _door.n <= 100 then
      pad.press("A")
    else
      _door.n = 0
      _door.seated = false
    end
    return true
  end
  -- Align to EXACT door pixel only (ady==0 and adx==0)
  if adx > 0 then
    if adx <= 10 and (frame() % 50) < 12 then
      pad.press("Down")
    elseif px > tx then
      pad.press("Left")
    else
      pad.press("Right")
    end
    return true
  end
  if ady > 0 then
    if py < ty then
      pad.press("Down")
    else
      pad.press("Up")
    end
    return true
  end
  -- Exact (tx, ty): commit enter recipe immediately (no idle — upcmp C idle also works,
  -- but idle is unnecessary; start Up on first seated frame).
  _door.seated = true
  _door.n = 1
  pad.press("Up")
  return true
end
"""

const NavSkillLua* = """
-- navTo(tx, ty): follow native nav.findPath waypoints over live collision ($7EE000).
-- Pathfinding is Nim-side (policy.nav); this skill only steers the d-pad.
-- Collision formula (disasm file 0x005F33 + page index 0x00565A..0x005670; gate 0x0029CC):
--   type = WRAM[$2B6E + slot*2]  (player slot 24)
--   xAdj = px - u16(ROM $C42A1F + type*2)
--   yAdj = py - u16(ROM $C42A41 + type*2) + u16(ROM $C42AEB + type*2)
--   wCnt = u16(ROM $C42AA7 + type*2); hCnt = u16(ROM $C42AC9 + type*2)
--   coll byte = page[((cy&0x3F)<<6)|(cx&0x3F)] with cx/cy from xAdj/yAdj >> 3
--   blocked iff (byte & 0xD0) != 0 over full hitbox columns/rows.
-- nav.findPath plans within ±24 coarse tiles (page wraps mod 64); far targets use frontier
-- steering and re-plan while moving. NO GLITCH FALLBACK: empty path × MAX_FAIL with no
-- net progress → print BLOCKED and return false. Never wiggle through solids.
-- Returns true while navigating; false when arrived (manhattan <= THRESH) or blocked.
-- Requires nav.walkable / nav.findPath (policy.nim) + escapeMenu.
-- TODO(magic): REPLAN_N/STUCK_N/THRESH/ARRIVE_WP tuned for Onett outdoor; cite 0x005F33 / 0x0029CC.

local THRESH = 12
local REPLAN_N = 120
local STUCK_N = 30
-- Waypoints are pixel-resolution (turns + every 8px); arrive tight so corners
-- in narrow 01/03 corridors are not cut into walls.
local ARRIVE_WP = 3
local OFF_PATH = 16
local MAX_FAIL = 8
-- After an empty plan, wait before re-planning: the live collision page
-- streams during area transitions and can read momentarily solid — 8
-- back-to-back empty plans in 8 frames was a false BLOCKED (2026-07-09).
local EMPTY_COOLDOWN = 30
-- BLOCKED also requires no net progress for this many frames.
local NO_PROGRESS_N = 600
local ROOM_JUMP = 0x80

local _nav = {
  path = nil,
  pi = 1,
  tx = nil, ty = nil,
  lx = nil, ly = nil,
  last_plan_f = -9999,
  stuck = 0,
  fails = 0,
  best_d = nil,
  blocked = false,
  blocked_printed = false,
}

function navWalkable(px, py)
  return nav.walkable(px, py)
end

local function needReplan(px, py, f)
  if not _nav.path or #_nav.path == 0 then
    return true
  end
  if f - _nav.last_plan_f >= REPLAN_N then
    return true
  end
  if _nav.lx and (math.abs(px - _nav.lx) > ROOM_JUMP or math.abs(py - _nav.ly) > ROOM_JUMP) then
    return true
  end
  if _nav.stuck >= STUCK_N then
    return true
  end
  local wp = _nav.path[_nav.pi]
  if wp then
    local d = math.abs(px - wp.x) + math.abs(py - wp.y)
    if d > OFF_PATH then
      return true
    end
  end
  return false
end

function navTo(tx, ty)
  if escapeMenu() then
    return true
  end
  local f = frame()
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local adx = math.abs(tx - px)
  local ady = math.abs(ty - py)
  local dist = adx + ady

  if _nav.tx ~= tx or _nav.ty ~= ty then
    _nav.tx = tx
    _nav.ty = ty
    _nav.path = nil
    _nav.pi = 1
    _nav.fails = 0
    _nav.stuck = 0
    _nav.best_d = dist
    _nav.blocked = false
    _nav.blocked_printed = false
    _nav.last_plan_f = -9999
    _nav.last_prog_f = f
    _nav.lx = nil
    _nav.ly = nil
  end

  if _nav.blocked then
    return false
  end

  if dist <= THRESH then
    _nav.path = nil
    _nav.tx = nil
    _nav.ty = nil
    return false
  end

  if _nav.best_d == nil or dist < _nav.best_d then
    _nav.best_d = dist
    _nav.fails = 0
    _nav.last_prog_f = f
  end

  if _nav.lx == px and _nav.ly == py then
    _nav.stuck = _nav.stuck + 1
  else
    _nav.stuck = 0
  end

  if needReplan(px, py, f) then
    local path = nav.findPath(tx, ty)
    _nav.last_plan_f = f
    _nav.stuck = 0
    if path == nil or #path == 0 then
      -- Blocked. Distinguish a MOVER (a patrolling NPC — the meteor cops) from
      -- a terrain wall: nav.blockedByMover is true when routing around NPCs
      -- fails but the terrain-only path exists. Movers pass on their own, so
      -- WAIT (hold still, re-plan soon, don't accrue fails) instead of the
      -- false BLOCKED that shut prior runs down (docs/llm-benchmarks MC-1).
      _nav.path = nil
      _nav.pi = 1
      if nav.blockedByMover(tx, ty) then
        _nav.last_plan_f = f - REPLAN_N + 8   -- re-plan again in ~8 frames
        _nav.last_prog_f = f                   -- waiting IS progress, not a stall
        return true                            -- hold position; let the NPC move
      end
      _nav.fails = _nav.fails + 1
      -- Back off before the next plan (page may be mid-stream).
      _nav.last_plan_f = f + EMPTY_COOLDOWN - REPLAN_N
      if _nav.fails >= MAX_FAIL and f - (_nav.last_prog_f or f) >= NO_PROGRESS_N then
        if not _nav.blocked_printed then
          print(string.format("navTo: BLOCKED no path to (%d,%d)", tx, ty))
          _nav.blocked_printed = true
        end
        _nav.blocked = true
        return false
      end
    else
      _nav.path = path
      _nav.pi = 1
      if dist < (_nav.best_d or dist) + 4 then
        _nav.fails = 0
      end
    end
  end

  if _nav.blocked then
    return false
  end

  if _nav.path and #_nav.path > 0 then
    while _nav.pi <= #_nav.path do
      local wp = _nav.path[_nav.pi]
      if math.abs(px - wp.x) + math.abs(py - wp.y) <= ARRIVE_WP then
        _nav.pi = _nav.pi + 1
      else
        break
      end
    end
    local aimX, aimY
    if _nav.pi > #_nav.path then
      aimX, aimY = tx, ty
    else
      local wp = _nav.path[_nav.pi]
      aimX, aimY = wp.x, wp.y
    end
    -- Hold BOTH axes when both deltas are nonzero: the 01/03 slope/stair tiles
    -- on hillsides (Onett crest corridor) only move the player on DIAGONAL
    -- input (why the old probes needed "stuck-wiggle"). Walls make diagonal
    -- presses slide along them, so this is safe on straight corridors too.
    local dx = aimX - px
    local dy = aimY - py
    if dx ~= 0 then
      pad.press((dx > 0) and "Right" or "Left")
    end
    if dy ~= 0 then
      pad.press((dy > 0) and "Down" or "Up")
    end
    -- Axis-pure aim frozen on a slope tile: slopes only move on DIAGONAL
    -- input, so alternate a perpendicular press while still pushing the main
    -- axis (normal d-pad input, not glitching). Cleared as soon as we move.
    if _nav.stuck > 8 then
      if dy ~= 0 and dx == 0 then
        pad.press(((f // 8) % 2 == 0) and "Left" or "Right")
      elseif dx ~= 0 and dy == 0 then
        pad.press(((f // 8) % 2 == 0) and "Up" or "Down")
      end
    end
  end

  _nav.lx = px
  _nav.ly = py
  return true
end
"""

const FollowTrailSkillLua* = """
-- followTrail(points): track a dense mutually-reachable point chain as a
-- *reachability trail*, not greedy nav. Each adjacent point is close (~20-60px)
-- and was walked by a human, so direct d-pad drive reaches it without navTo's
-- out-of-window frontier steering (which local-mins on detours that increase
-- euclidean-to-goal, e.g. the Pokey SW→west→climb loop).
--
-- Invariants:
--   * Never skip ahead of the player's real position — index advances only on
--     genuine arrival (manhattan <= ARRIVE).
--   * Drive DIRECTLY toward the current trail point. Dominant-axis first
--     (diagonals into a solid axis cancel ALL movement in EB — verified on the
--     Onett western climb at (0x0608,0x018A): Left+Up stuck, pure Up free).
--     After brief stuck, add the secondary axis (slopes) then slope-wiggle.
--   * If wall-stuck for RECOVER_N: navTo the SAME trail point. If still no
--     progress for RETREAT_N frames of recovery, step the index back one
--     (re-anchor on the previous human sample) and resume. No glitch/clip.
--
-- points = {{x=, y=}, ...} in order. Pass a stable table (store in a global
-- once) so the follower keeps its index across frames.
-- Returns true while following; false when arrived at the last point.
-- Requires: escapeMenu, navTo (recovery), pad, mem, frame.
-- TODO(magic): ARRIVE/RECOVER_N/RETREAT_N tuned on TAS 20260709-225653;
--   climb freeze (0x0608,0x018A) is the calibration case.

local TRAIL_ARRIVE = 8
local TRAIL_RECOVER_N = 40
local TRAIL_RETREAT_N = 90
local TRAIL_DUAL_N = 10
local TRAIL_WIGGLE_N = 20
local TRAIL_ROOM_JUMP = 0x80

local _trail = {
  key = nil,
  i = 1,
  lx = nil,
  ly = nil,
  stuck = 0,
  wp_best = nil,
  recovering = false,
  rec_frames = 0,
  rec_best = nil,
}

function followTrail(points)
  if escapeMenu() then
    return true
  end
  if points == nil or #points == 0 then
    return false
  end

  -- Bind to table identity so a stable global trail keeps its index; a new
  -- table restarts from point 1 (caller should cache the trail once).
  if _trail.key ~= points then
    _trail.key = points
    _trail.i = 1
    _trail.lx = nil
    _trail.ly = nil
    _trail.stuck = 0
    _trail.wp_best = nil
    _trail.recovering = false
    _trail.rec_frames = 0
    _trail.rec_best = nil
  end

  local f = frame()
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)

  if _trail.lx and (math.abs(px - _trail.lx) > TRAIL_ROOM_JUMP or
      math.abs(py - _trail.ly) > TRAIL_ROOM_JUMP) then
    _trail.lx = px
    _trail.ly = py
    _trail.stuck = 0
    _trail.wp_best = nil
    _trail.recovering = false
    _trail.rec_frames = 0
    _trail.rec_best = nil
  end

  -- Advance only on genuine arrival; never jump past unreached detour points.
  while _trail.i <= #points do
    local wp = points[_trail.i]
    local d = math.abs(px - wp.x) + math.abs(py - wp.y)
    if d <= TRAIL_ARRIVE then
      if _trail.i >= #points then
        _trail.lx = px
        _trail.ly = py
        return false
      end
      _trail.i = _trail.i + 1
      _trail.stuck = 0
      _trail.wp_best = nil
      _trail.recovering = false
      _trail.rec_frames = 0
      _trail.rec_best = nil
    else
      break
    end
  end

  if _trail.i > #points then
    return false
  end

  local wp = points[_trail.i]
  local dist = math.abs(px - wp.x) + math.abs(py - wp.y)

  -- Progress-based stuck detection. Exact-position freeze misses the common
  -- case of grinding into a wall with 1px sub-pixel jitter (the reverse
  -- western-hill climb at (0x06D3,0x015E): pos wobbles by 1px but makes zero
  -- real progress toward the waypoint, so exact-match reset stuck forever and
  -- recovery never fired). Instead: stuck climbs whenever the manhattan
  -- distance to the current waypoint fails to improve. This lets the dual-axis
  -- (X-align to clear the wall) and navTo recovery below actually trigger.
  if _trail.wp_best == nil or dist < _trail.wp_best then
    _trail.wp_best = dist
    _trail.stuck = 0
  else
    _trail.stuck = _trail.stuck + 1
  end
  _trail.lx = px
  _trail.ly = py

  if _trail.stuck >= TRAIL_RECOVER_N then
    _trail.recovering = true
  end

  -- Recovery: local pixel BFS to the SAME trail index; retreat if no progress.
  if _trail.recovering then
    if _trail.rec_best == nil or dist < _trail.rec_best then
      _trail.rec_best = dist
      _trail.rec_frames = 0
    else
      _trail.rec_frames = _trail.rec_frames + 1
    end
    if _trail.rec_frames >= TRAIL_RETREAT_N and _trail.i > 1 then
      -- Same-point recovery is a dead pocket; re-anchor on previous sample.
      _trail.i = _trail.i - 1
      _trail.recovering = false
      _trail.stuck = 0
      _trail.wp_best = nil
      _trail.rec_frames = 0
      _trail.rec_best = nil
      wp = points[_trail.i]
    else
      local still = navTo(wp.x, wp.y)
      if still then
        return true
      end
      -- navTo arrived or blocked this frame.
      _trail.recovering = false
      _trail.stuck = 0
      _trail.rec_frames = 0
      _trail.rec_best = nil
      return true
    end
  end

  -- Direct drive (no path, no frontier). Dominant-axis first so a blocked
  -- secondary axis cannot cancel movement (EB diagonal-into-wall trap).
  local dx = wp.x - px
  local dy = wp.y - py
  local adx = math.abs(dx)
  local ady = math.abs(dy)
  if _trail.stuck < TRAIL_DUAL_N then
    if adx >= ady then
      if dx ~= 0 then
        pad.press((dx > 0) and "Right" or "Left")
      elseif dy ~= 0 then
        pad.press((dy > 0) and "Down" or "Up")
      end
    else
      if dy ~= 0 then
        pad.press((dy > 0) and "Down" or "Up")
      elseif dx ~= 0 then
        pad.press((dx > 0) and "Right" or "Left")
      end
    end
  else
    -- Stuck briefly: dual-axis for 01/03 slopes, then perpendicular wiggle.
    if dx ~= 0 then
      pad.press((dx > 0) and "Right" or "Left")
    end
    if dy ~= 0 then
      pad.press((dy > 0) and "Down" or "Up")
    end
    if _trail.stuck >= TRAIL_WIGGLE_N then
      if dy ~= 0 and dx == 0 then
        pad.press(((f // 8) % 2 == 0) and "Left" or "Right")
      elseif dx ~= 0 and dy == 0 then
        pad.press(((f // 8) % 2 == 0) and "Up" or "Down")
      end
    end
  end
  return true
end
"""

const IntentNavSkillLua* = """
-- Intent-level navigation over scene() perception (no hardcoded coordinates).
-- nearestEntity() -> {slot, dir, dist_tiles} or nil — first nearby_entities entry.
-- approach(slotOrDir) -> true while walking toward that entity via navTo on its
--   live WRAM pos; false when adjacent (dist_tiles <= 1) or entity missing.
-- talk(slotOrDir) -> approach, face, A, advanceDialogue(); true once a dialogue
--   window is open (and while advancing it).
-- goToward(name) -> landmarkTarget(name) then navTo; false when arrived
--   (manhattan <= 12). If navTo BLOCKs, step a bit in the landmark's scene dir
--   then replan (no glitch/clip). Requires landmarkTarget() + scene().
-- Entity pos: slot s at $0B8E+s*2 (X) / $0BCA+s*2 (Y); player slot 24 = $0BBE/$0BFA.
-- Requires: scene(), landmarkTarget, navTo/walkTo, escapeMenu, advanceDialogue, mem, pad, frame.
-- TODO(magic): adjacent dist_tiles<=1 and face+A cadence from probe_dialogue_harvest.

local function _intentParseEntities()
  local j = scene() or ""
  local body = j:match('"nearby_entities":%[([^%]]*)%]')
  local ents = {}
  if not body or body == "" then
    return ents
  end
  for slot, kind, dir, dist in body:gmatch(
      '"slot":(%d+),"kind":"([^"]*)","dir":"([^"]*)","dist_tiles":(%d+)') do
    ents[#ents + 1] = {
      slot = tonumber(slot),
      kind = kind,
      dir = dir,
      dist_tiles = tonumber(dist),
    }
  end
  return ents
end

local function _intentEntXY(slot)
  local i = slot * 2
  local ex = mem.read(0x0B8E + i) + 256 * mem.read(0x0B8E + i + 1)
  local ey = mem.read(0x0BCA + i) + 256 * mem.read(0x0BCA + i + 1)
  return ex, ey
end

local function _intentPlayerXY()
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  return px, py
end

local function _intentDistTiles(slot)
  local ex, ey = _intentEntXY(slot)
  local px, py = _intentPlayerXY()
  return math.floor((math.abs(ex - px) + math.abs(ey - py)) / 8)
end

local function _intentResolve(slotOrDir)
  local ents = _intentParseEntities()
  if slotOrDir == nil then
    if #ents == 0 then return nil end
    return ents[1]
  end
  if type(slotOrDir) == "number" then
    for _, e in ipairs(ents) do
      if e.slot == slotOrDir then
        return e
      end
    end
    -- Slot known but off the nearby list: still target live coords.
    local d = _intentDistTiles(slotOrDir)
    return {slot = slotOrDir, dir = "here", dist_tiles = d}
  end
  local want = tostring(slotOrDir)
  for _, e in ipairs(ents) do
    if e.dir == want then
      return e
    end
  end
  return nil
end

local _talk = {face_n = 0, slot = nil, opened = false}

function nearestEntity()
  local ents = _intentParseEntities()
  if #ents == 0 then
    return nil
  end
  return ents[1]
end

function approach(slotOrDir)
  if escapeMenu() then
    return true
  end
  local e = _intentResolve(slotOrDir)
  if e == nil then
    return false
  end
  local dist = _intentDistTiles(e.slot)
  if dist <= 1 then
    return false
  end
  -- Stand one tile out from the entity (not on top of them) so A can talk.
  local ex, ey = _intentEntXY(e.slot)
  local px, py = _intentPlayerXY()
  local dx = ex - px
  local dy = ey - py
  local tx, ty = ex, ey
  if math.abs(dx) >= math.abs(dy) then
    if dx ~= 0 then
      tx = ex - ((dx > 0) and 8 or -8)
    end
  else
    if dy ~= 0 then
      ty = ey - ((dy > 0) and 8 or -8)
    end
  end
  if navTo then
    return navTo(tx, ty)
  end
  walkTo(tx, ty)
  return true
end

function talk(slotOrDir)
  if escapeMenu() then
    return true
  end
  local win0 = mem.read(0x8650)
  local win1 = mem.read(0x8654)
  if win0 ~= 0xFF or win1 ~= 0xFF then
    _talk.opened = true
    if advanceDialogue then
      advanceDialogue()
    end
    return true
  end
  local e = _intentResolve(slotOrDir)
  if e == nil then
    return false
  end
  if _talk.slot ~= e.slot then
    _talk.slot = e.slot
    _talk.face_n = 0
    _talk.opened = false
  end
  if approach(e.slot) then
    _talk.face_n = 0
    return false
  end
  -- Adjacent: face briefly (no A yet), then A pulses without holding d-pad.
  _talk.face_n = _talk.face_n + 1
  local dir = e.dir or ""
  if _talk.face_n <= 10 then
    if dir:find("N", 1, true) then
      pad.press("Up")
    elseif dir:find("S", 1, true) then
      pad.press("Down")
    end
    if dir:find("E", 1, true) then
      pad.press("Right")
    elseif dir:find("W", 1, true) then
      pad.press("Left")
    end
    return false
  end
  if (_talk.face_n % 8) < 3 then
    pad.press("A")
  end
  return _talk.opened
end

-- goToward(name): travel to a named landmark of the current area with no
-- coordinates in the policy. Engine resolves name -> (x,y) via landmarkTarget.
local GO_ARRIVE = 12
local GO_UNSTICK_N = 48
local _go = {unstick = 0, dir = nil, name = nil}

local function _intentLandmarkDir(name)
  local j = scene() or ""
  local body = j:match('"landmarks":%[([^%]]*)%]')
  if not body or body == "" then
    return nil
  end
  for nm, dir in body:gmatch('"name":"([^"]*)","dir":"([^"]*)"') do
    if nm == name then
      return dir
    end
  end
  return nil
end

local function _intentPressDir(dir)
  if not dir or dir == "" or dir == "here" then
    return
  end
  if dir:find("N", 1, true) then
    pad.press("Up")
  end
  if dir:find("S", 1, true) then
    pad.press("Down")
  end
  if dir:find("E", 1, true) then
    pad.press("Right")
  end
  if dir:find("W", 1, true) then
    pad.press("Left")
  end
end

function goToward(name)
  if escapeMenu() then
    return true
  end
  if not landmarkTarget then
    return false
  end
  local x, y = landmarkTarget(name)
  if x == nil then
    return false
  end
  local px, py = _intentPlayerXY()
  local dist = math.abs(x - px) + math.abs(y - py)
  if dist <= GO_ARRIVE then
    _go.unstick = 0
    return false
  end
  if _go.name ~= name then
    _go.name = name
    _go.unstick = 0
    _go.dir = nil
  end
  -- After a BLOCKED report: step in the landmark's compass dir a bit, then
  -- let navTo replan from the new pose (never clip through solids).
  if _go.unstick > 0 then
    _go.unstick = _go.unstick - 1
    _intentPressDir(_go.dir)
    return true
  end
  if navTo then
    if navTo(x, y) then
      return true
    end
    -- false: arrived (THRESH) or honestly BLOCKED.
    px, py = _intentPlayerXY()
    if math.abs(x - px) + math.abs(y - py) <= GO_ARRIVE then
      return false
    end
    local dir = _intentLandmarkDir(name) or "N"
    _go.dir = dir
    _go.unstick = GO_UNSTICK_N
    -- Clear navTo's blocked latch (same tx/ty keeps blocked=true forever).
    navTo(px, py)
    _intentPressDir(dir)
    return true
  end
  walkTo(x, y)
  return true
end
"""

proc currentRoomLabel*(snes: SnesBus): string =
  ## Human label for the LLM summary (bedroom / outside / title etc).
  let pct = touchGrassPercent(snes)
  if pct == 0: return "title"
  if pct == 25: return "bedroom"
  if pct < 100: return "house_interior"
  return "outside_onett"

proc battleFixtureOk*(snes: SnesBus): (bool, string) =
  ## Pure validator for a battle-capable start (no I/O, no Lua).
  ## Asserts tg==50 (battle box), in_battle flag set, player pos in documented box.
  ## Returns (ok, diagnostic). Used by gate tool and llm_ai startup for battle scenario.
  let tg = touchGrassPercent(snes)
  if tg != 50:
    return (false, "tg=" & $tg & " (expected 50 for battle)")

  let flag = readU8(snes, 0x4DBA)
  if flag == 0:
    return (false, "in_battle flag at 0x4DBA is 0 (expected !=0)")

  let pidx = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + pidx)
  let py = readU16(snes, WorldYBase + pidx)
  let inBox = (px >= BattleBoxX1 and px <= BattleBoxX2 and py >= BattleBoxY1 and py <= BattleBoxY2)
  if not inBox:
    return (false, "pos not in battle box (got " & $px & "," & $py & ")")

  # Reject DEAD battle fixtures (2026-07-11, grok battle RE): $4DBA==1 but the
  # PPU is not in the battle's rendering mode, so no command menu is reachable
  # and A does nothing. A real EarthBound battle renders in BG mode 0
  # ($2105 low 3 bits). The old gate passed these glitched states.
  let bgMode = snes.ppuRegs[0x05].int and 0x07
  if bgMode != 0:
    return (false, "BGMODE=" & $bgMode & " (dead fixture — real battle is mode 0)")

  return (true, "battle fixture OK")
