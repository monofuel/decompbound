## Pure mock / seed policy strings for llm_ai verification scenarios.
## Nav (touch grass) and battle paths stay separate — house walk is waypoints only.

import
  std/strutils

const
  ## Deterministic bedroom → outside (tg 25 → 75 → 100). d-pad / walkTo only.
  ## After stairs, south first to y~0x0178 — pure east from (1D30,0150) dies on furniture.
  NavHousePolicy* = """-- NOTE: pure house walk; escapeMenu+walkTo; no A; winBattle only if in_battle
-- Touch grass: bedroom -> stairs -> sitting room (south) -> east door -> outside.
-- Waypoints verified for 25->75->100 from bin/states/llm/bedroom.state (seed of game_start).
function update()
  if escapeMenu() then return end
  if mem.read(0x4DBA) ~= 0 then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- already outside Onett band
  if px < 0x1C00 then
    walkTo(0x0A60, 0x0158)
    return
  end
  -- upstairs bedroom: leave west to hall/stairs
  if py >= 0x0300 and px >= 0x1F00 then
    walkTo(0x1F00, 0x0450)
    return
  end
  -- upstairs hall: continue west toward stairwell
  if py >= 0x0300 and px > 0x1D50 then
    walkTo(0x1D40, 0x03E8)
    return
  end
  -- stairwell / transition approach
  if py >= 0x0300 then
    walkTo(0x1CC0, 0x03E8)
    return
  end
  -- downstairs: SOUTH first into open sitting area (do not hug y=0x0140)
  if py < 0x0168 and px < 0x1DC0 then
    walkTo(0x1D30, 0x0178)
    return
  end
  -- east across sitting room
  if px < 0x1E40 then
    walkTo(0x1E70, 0x0170)
    return
  end
  -- approach front door height then push east through door
  if math.abs(py - 0x0150) > 6 then
    walkTo(0x1E80, 0x0148)
    return
  end
  walkTo(0x1F40, 0x0148)
end
"""

  BattlePolicy* = """function update()
  winBattle()
end
"""

  ## After touch-grass (tg 100): keep walking Onett streets so the house display
  ## does not idle at the door. Placeholder waypoints near Ness house exit; no A spam.
  ExploreOnettPolicy* = """-- NOTE: explore Onett after outside; cycle street walkTo targets; no battle focus
-- Seed for display loop once tg==100. Coords are soft placeholders near house exit.
function update()
  if escapeMenu() then return end
  if mem.read(0x4DBA) ~= 0 then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- still indoors: finish house path east to door / outside band
  if px >= 0x1C00 then
    if py >= 0x0300 then
      walkTo(0x1CC0, 0x03E8)
      return
    end
    if py < 0x0168 and px < 0x1DC0 then
      walkTo(0x1D30, 0x0178)
      return
    end
    if px < 0x1E40 then
      walkTo(0x1E70, 0x0170)
      return
    end
    walkTo(0x1F40, 0x0148)
    return
  end
  -- outside: cycle four soft street targets (~10s each @60fps)
  local t = math.floor(frame() / 600) % 4
  if t == 0 then
    walkTo(0x0A60, 0x0158)
  elseif t == 1 then
    walkTo(0x0B40, 0x0188)
  elseif t == 2 then
    walkTo(0x09A0, 0x01A8)
  else
    walkTo(0x0AC0, 0x0128)
  end
end
"""

  ## Pokey % seed: exit Ness house if needed, then real-pathfind up the hill.
  ## Pokey is outdoors at the meteor crash site (NOT Picky indoors at Minch).
  ## Route (verified 2026-07-09, probe_meteor_route via navTo): door (0x0A60,
  ## 0x0158) -> slight south -> west lower path -> winding slope corridor
  ## north -> crest (0x0A18,0x00CC) -> plateau north edge ~Y=0x00B8.
  ## navTo threads the whole thing in ~450 frames (pixel-space A* over the
  ## live collision page + diagonal slope input). Hard wall at Y=0x00B8 from
  ## onett_start; meteor/Pokey coords beyond it TBD (collision-map RE ticket).
  ## Never doorEnter. Needs: escapeMenu, walkTo, navTo, advanceDialogue, winBattle.
  PokeyVisitPolicy* = """-- NOTE: Pokey % seed — outdoor meteor hill via navTo, NOT Minch house / Picky.
-- Indoors Ness: NavHouse exit (walkTo waypoints). Outside: navTo crest then plateau.
-- navTo = real A* over the live collision page; no stuck-wiggle, no glitching.
function update()
  if escapeMenu() then return end
  if mem.read(0x4DBA) ~= 0 then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- still indoors Ness house: NavHouse exit (do not treat Minch as goal)
  if px >= 0x1C00 then
    if advanceDialogue() then return end
    if py >= 0x0300 and px >= 0x1F00 then
      walkTo(0x1F00, 0x0450)
      return
    end
    if py >= 0x0300 and px > 0x1D50 then
      walkTo(0x1D40, 0x03E8)
      return
    end
    if py >= 0x0300 then
      walkTo(0x1CC0, 0x03E8)
      return
    end
    if py < 0x0168 and px < 0x1DC0 then
      walkTo(0x1D30, 0x0178)
      return
    end
    if px < 0x1E40 then
      walkTo(0x1E70, 0x0170)
      return
    end
    if math.abs(py - 0x0150) > 6 then
      walkTo(0x1E80, 0x0148)
      return
    end
    walkTo(0x1F40, 0x0148)
    return
  end
  -- outdoors: dialogue only when a window is open (never A-spam walk)
  if advanceDialogue() then return end
  -- Human-verified route ladder (TAS 20260709-225653): SW descent -> west
  -- road -> western climb -> ridge east -> meteor site. navTo threads each
  -- leg; advance to the next waypoint when close. Persistent index survives
  -- unchanged-policy ticks (mock never rewrites this chunk).
  _pokeyWp = _pokeyWp or 1
  local W = {
    {x=0x0A60, y=0x0158},
    {x=0x0A4A, y=0x0192},
    {x=0x0A09, y=0x01BA},
    {x=0x09EA, y=0x01FE},
    {x=0x09E0, y=0x024E},
    {x=0x099A, y=0x026D},
    {x=0x0948, y=0x026D},
    {x=0x08FB, y=0x0260},
    {x=0x08B3, y=0x0246},
    {x=0x0871, y=0x0220},
    {x=0x0831, y=0x01F1},
    {x=0x07F0, y=0x01C8},
    {x=0x07B5, y=0x01F1},
    {x=0x076C, y=0x0208},
    {x=0x071E, y=0x01FC},
    {x=0x06CD, y=0x01F8},
    {x=0x067A, y=0x01F8},
    {x=0x063A, y=0x01CD},
    {x=0x0613, y=0x018B},
    {x=0x05F3, y=0x0146},
    {x=0x0631, y=0x013A},
    {x=0x0677, y=0x0150},
    {x=0x06BC, y=0x0175},
    {x=0x06D8, y=0x013E},
    {x=0x06DC, y=0x00ED},
    {x=0x0716, y=0x00B2},
    {x=0x0766, y=0x00B0},
    {x=0x07A4, y=0x00D4},
    {x=0x07B6, y=0x0116},
    {x=0x0807, y=0x0116},
    {x=0x0854, y=0x0105},
    {x=0x0858, y=0x0102}, -- meteor site, Pokey just north
  }
  local wp = W[math.min(_pokeyWp, #W)]
  local adx = math.abs(px - wp.x) + math.abs(py - wp.y)
  if adx <= 0x18 and _pokeyWp < #W then
    _pokeyWp = _pokeyWp + 1
    return
  end
  -- At the final spot: face Pokey (up) and talk; the scene may auto-trigger.
  if _pokeyWp >= #W and adx <= 0x18 then
    if (frame() % 16) < 8 then pad.press("Up") end
    if (frame() % 16) == 8 then pad.press("A") end
    return
  end
  if navTo(wp.x, wp.y) then return end
  -- navTo gave up (blocked/local-minimum): retreat one waypoint and retry.
  if _pokeyWp > 1 then _pokeyWp = _pokeyWp - 1 end
end
"""

proc selectMockPolicy*(loadStateSlot: int): string =
  ## LLM-namespace slot1 battle fixture → BattlePolicy; otherwise house nav.
  ## Numeric slots are bin/states/llm/slotN.state, not make-play slots.
  ## Named seeds (not slot-mapped yet): ExploreOnettPolicy, PokeyVisitPolicy.
  if loadStateSlot == 1:
    BattlePolicy
  else:
    NavHousePolicy

proc selectMockPolicyByName*(name: string): string =
  ## Named scenario seeds for harness / probes (case-insensitive keys).
  ## Unknown names fall back to NavHousePolicy.
  case name.toLowerAscii()
  of "battle": BattlePolicy
  of "nav", "navhouse", "tg", "touchgrass": NavHousePolicy
  of "explore", "exploreonett", "onett": ExploreOnettPolicy
  of "pokey", "pokeyvisit", "pokey_pct": PokeyVisitPolicy
  else: NavHousePolicy
