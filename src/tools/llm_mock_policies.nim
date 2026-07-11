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

  ## Pokey % seed: exit Ness house if needed, then followTrail the human TAS
  ## breadcrumb chain to Pokey at the outdoor meteor site (NOT Minch / Picky).
  ## Trail = dense positions from TAS 20260709-225653 (every ~30f, mutually
  ## reachable). followTrail drives dual-axis direct to each point; navTo only
  ## as same-point recovery if wall-stuck. No frontier steering, no glitch.
  ## Never doorEnter. Needs: escapeMenu, walkTo, followTrail, navTo,
  ## advanceDialogue, winBattle.
  PokeyVisitPolicy* = """-- NOTE: Pokey % seed — outdoor meteor via followTrail, NOT Minch / Picky.
-- Indoors Ness: NavHouse exit (walkTo waypoints). Outside: dense human trail.
-- followTrail = reachability chain (direct d-pad); navTo only for recovery.
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
  -- Dense human trail (TAS 20260709-225653, unique sequential samples).
  -- Cached once so followTrail keeps its index across frames / reloads.
  _pokeyTrail = _pokeyTrail or {
    {x=0x0A60, y=0x0158},
    {x=0x0A4B, y=0x0169},
    {x=0x0A4A, y=0x0192},
    {x=0x0A2F, y=0x01AF},
    {x=0x0A09, y=0x01BA},
    {x=0x09EC, y=0x01D7},
    {x=0x09EA, y=0x01FE},
    {x=0x09EA, y=0x0229},
    {x=0x09E0, y=0x024E},
    {x=0x09C3, y=0x026B},
    {x=0x099A, y=0x026D},
    {x=0x0971, y=0x026D},
    {x=0x0948, y=0x026D},
    {x=0x0920, y=0x026D},
    {x=0x08FB, y=0x0260},
    {x=0x08D4, y=0x025B},
    {x=0x08B3, y=0x0246},
    {x=0x0896, y=0x0228},
    {x=0x0871, y=0x0220},
    {x=0x0850, y=0x020F},
    {x=0x0831, y=0x01F1},
    {x=0x0814, y=0x01D4},
    {x=0x07F0, y=0x01C8},
    {x=0x07D4, y=0x01DA},
    {x=0x07B5, y=0x01F1},
    {x=0x0793, y=0x0203},
    {x=0x076C, y=0x0208},
    {x=0x0742, y=0x0208},
    {x=0x071E, y=0x01FC},
    {x=0x06F8, y=0x01F8},
    {x=0x06CD, y=0x01F8},
    {x=0x06A4, y=0x01F8},
    {x=0x067A, y=0x01F8},
    {x=0x0658, y=0x01EB},
    {x=0x063A, y=0x01CD},
    {x=0x061D, y=0x01B0},
    {x=0x0613, y=0x018B},
    {x=0x0600, y=0x016B},
    {x=0x05F3, y=0x0146},
    {x=0x060B, y=0x0131},
    {x=0x0631, y=0x013A},
    {x=0x0659, y=0x0138},
    {x=0x0677, y=0x0150},
    {x=0x0695, y=0x016E},
    {x=0x06BC, y=0x0175},
    {x=0x06D8, y=0x0168},
    {x=0x06D8, y=0x013E},
    {x=0x06D8, y=0x0114},
    {x=0x06DC, y=0x00ED},
    {x=0x06F9, y=0x00D0},
    {x=0x0716, y=0x00B2},
    {x=0x073F, y=0x00B0},
    {x=0x0766, y=0x00B0},
    {x=0x078F, y=0x00B1},
    {x=0x07A4, y=0x00D4},
    {x=0x07A4, y=0x00FD},
    {x=0x07B6, y=0x0116},
    {x=0x07DF, y=0x0116},
    {x=0x0807, y=0x0116},
    {x=0x082F, y=0x0112},
    {x=0x0854, y=0x0105},
    {x=0x0858, y=0x00FA},
  }
  if followTrail(_pokeyTrail) then return end
  -- At talk spot (0x0858,0x00FA): face Pokey (up) and press A; advanceDialogue
  -- (above) drains window slot1 $8654 once the scene fires.
  if (frame() % 16) < 8 then pad.press("Up") end
  if (frame() % 16) == 8 then pad.press("A") end
end
"""

  ## Pokey-knock % seed: reverse of PokeyVisit outdoor trail (meteor → door),
  ## doorEnter into Ness house, reverse NavHouse upstairs to bed, A to sleep.
  ## Trail = reverse of TAS 20260709-225653 dense samples. Needs: escapeMenu,
  ## walkTo, followTrail, navTo, doorEnter, advanceDialogue, winBattle.
  PokeyKnockPolicy* = """-- NOTE: pokey_knock seed — reverse trail home, enter house, bed, knock.
-- Outdoor: followTrail reverse of human TAS corridor. Indoor: reverse NavHouse.
-- At bed: face + A to sleep; advanceDialogue drains the knock window.
function update()
  if escapeMenu() then return end
  if mem.read(0x4DBA) ~= 0 then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- Indoors Ness house: reverse of NavHouse (door → stairs → bedroom → bed).
  if px >= 0x1C00 then
    if advanceDialogue() then return end
    -- Upstairs bedroom (tg 25 band): approach bed and press A to sleep.
    -- Bed spawn from game_start is ~(0x1FB8,0x0452); walk onto it + A.
    if py >= 0x0300 and px >= 0x1F00 then
      local bedX, bedY = 0x1FB8, 0x0450
      if math.abs(px - bedX) + math.abs(py - bedY) > 12 then
        walkTo(bedX, bedY)
        return
      end
      if (frame() % 16) < 8 then pad.press("Up") end
      if (frame() % 16) == 8 then pad.press("A") end
      return
    end
    -- Upstairs hall: east into bedroom
    if py >= 0x0300 and px > 0x1D50 then
      walkTo(0x1F40, 0x0450)
      return
    end
    -- Upstairs near stairwell: east toward hall
    if py >= 0x0300 then
      walkTo(0x1D80, 0x03E8)
      return
    end
    -- Downstairs: west to sitting, then north-west into stairwell
    if py < 0x0168 and px < 0x1DC0 then
      walkTo(0x1CC0, 0x03E8)
      return
    end
    if px > 0x1E40 then
      walkTo(0x1D30, 0x0178)
      return
    end
    if math.abs(py - 0x0178) > 8 then
      walkTo(0x1D30, 0x0178)
      return
    end
    walkTo(0x1CC0, 0x03E8)
    return
  end
  -- Outdoors: dialogue first, then reverse trail, then door enter.
  if advanceDialogue() then return end
  -- Dense reverse of TAS 20260709-225653 (meteor talk → house door).
  -- Cached once so followTrail keeps its index across frames / reloads.
  _knockTrail = _knockTrail or {
    {x=0x0858, y=0x0128},
    {x=0x0854, y=0x0105},
    {x=0x082F, y=0x0112},
    {x=0x0807, y=0x0116},
    {x=0x07DF, y=0x0116},
    {x=0x07B6, y=0x0116},
    {x=0x07A4, y=0x00FD},
    {x=0x07A4, y=0x00D4},
    {x=0x078F, y=0x00B1},
    {x=0x0766, y=0x00B0},
    {x=0x073F, y=0x00B0},
    {x=0x0716, y=0x00B2},
    {x=0x06F9, y=0x00D0},
    {x=0x06DC, y=0x00ED},
    {x=0x06D8, y=0x0114},
    {x=0x06D8, y=0x013E},
    {x=0x06D8, y=0x0168},
    {x=0x06BC, y=0x0175},
    {x=0x0695, y=0x016E},
    {x=0x0677, y=0x0150},
    {x=0x0659, y=0x0138},
    {x=0x0631, y=0x013A},
    {x=0x060B, y=0x0131},
    {x=0x05F3, y=0x0146},
    {x=0x0600, y=0x016B},
    {x=0x0613, y=0x018B},
    {x=0x061D, y=0x01B0},
    {x=0x063A, y=0x01CD},
    {x=0x0658, y=0x01EB},
    {x=0x067A, y=0x01F8},
    {x=0x06A4, y=0x01F8},
    {x=0x06CD, y=0x01F8},
    {x=0x06F8, y=0x01F8},
    {x=0x071E, y=0x01FC},
    {x=0x0742, y=0x0208},
    {x=0x076C, y=0x0208},
    {x=0x0793, y=0x0203},
    {x=0x07B5, y=0x01F1},
    {x=0x07D4, y=0x01DA},
    {x=0x07F0, y=0x01C8},
    {x=0x0814, y=0x01D4},
    {x=0x0831, y=0x01F1},
    {x=0x0850, y=0x020F},
    {x=0x0871, y=0x0220},
    {x=0x0896, y=0x0228},
    {x=0x08B3, y=0x0246},
    {x=0x08D4, y=0x025B},
    {x=0x08FB, y=0x0260},
    {x=0x0920, y=0x026D},
    {x=0x0948, y=0x026D},
    {x=0x0971, y=0x026D},
    {x=0x099A, y=0x026D},
    {x=0x09C3, y=0x026B},
    {x=0x09E0, y=0x024E},
    {x=0x09EA, y=0x0229},
    {x=0x09EA, y=0x01FE},
    {x=0x09EC, y=0x01D7},
    {x=0x0A09, y=0x01BA},
    {x=0x0A2F, y=0x01AF},
    {x=0x0A4A, y=0x0192},
    {x=0x0A4B, y=0x0169},
    {x=0x0A60, y=0x0158},
  }
  if followTrail(_knockTrail) then return end
  -- At door outdoor tile: doorEnter (Up commit + A) into Ness house.
  if doorEnter(0x0A60, 0x0158) then return end
  -- Far from door somehow: re-nav to door.
  navTo(0x0A60, 0x0158)
end
"""

proc selectMockPolicy*(loadStateSlot: int): string =
  ## LLM-namespace slot1 battle fixture → BattlePolicy; otherwise house nav.
  ## Numeric slots are bin/states/llm/slotN.state, not make-play slots.
  ## Named seeds (not slot-mapped yet): ExploreOnettPolicy, PokeyVisitPolicy,
  ## PokeyKnockPolicy.
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
  of "knock", "pokeyknock", "pokey_knock", "pokey_knock_pct": PokeyKnockPolicy
  else: NavHousePolicy
