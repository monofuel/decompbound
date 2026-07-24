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
  if inBattle() then winBattle(); return end
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
  if inBattle() then winBattle(); return end
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

  ## Pokey % seed: exit Ness house if needed, then followRoute the engine-held
  ## onett_to_crater trail to Pokey at the outdoor meteor site (NOT Minch /
  ## Picky). One route source with the Agent — no inline trail copy.
  ## Never doorEnter. Needs: escapeMenu, walkTo, followRoute, navTo,
  ## advanceDialogue, winBattle.
  PokeyVisitPolicy* = """-- NOTE: Pokey % seed — outdoor meteor via followRoute, NOT Minch / Picky.
-- Indoors Ness: NavHouse exit (walkTo waypoints). Outside: onett_to_crater.
-- followRoute = engine-held reachability chain (same trail as Agent).
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
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
  -- Canonical door -> meteor corridor (engine NamedRoutesLua).
  if followRoute("onett_to_crater") then return end
  -- At talk spot (0x0858,0x00FA): face Pokey (up) and press A; advanceDialogue
  -- (above) drains window slot1 $8654 once the scene fires.
  if (frame() % 16) < 8 then pad.press("Up") end
  if (frame() % 16) == 8 then pad.press("A") end
end
"""

  ## Pokey-knock % seed: followRoute("crater_to_onett") home (meteor → door),
  ## talk the door officer inside, reverse NavHouse upstairs to bed, A to sleep.
  ## The home route is engine-held (same skill library as the Agent), so this
  ## seed and qwen share ONE crater→door trail. Needs: escapeMenu, walkTo,
  ## followRoute, navTo, advanceDialogue, winBattle.
  ## (Converged 2026-07-20: crater_to_onett is a dedicated forward reverse trail,
  ## so it seats where a naive onett_to_crater reverse local-mined at knock=10.)
  PokeyKnockPolicy* = """-- NOTE: pokey_knock seed — reverse trail home, enter house, bed, knock.
-- Outdoor: followTrail reverse of human TAS corridor. Indoor: reverse NavHouse.
-- At bed: face + A to sleep; advanceDialogue drains the knock window.
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
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
  -- Reverse home trail lives in the skill library as followRoute("crater_to_onett")
  -- (verified TAS 20260709-225653 dense samples) — the up leg's mirror, its OWN
  -- forward trail so followTrail seats it (a naive onett_to_crater reverse local-
  -- mins on the climb: knock=10 stall 2026-07-17). Same points as the old inline
  -- _knockTrail, now single-sourced with the Agent.
  -- At the front door post-meteor the door NPC stands ON the door tile
  -- (talk to them to enter — live dialogue, not hardcoded). That tile
  -- is therefore unreachable, so followTrail's last waypoint never "arrives"
  -- and doorEnter's exact-pixel Up+A recipe can never seat. The real entry is
  -- to TALK to the cop: once near the door, face it (Up) and press A;
  -- advanceDialogue (above) drains the line, which warps Ness inside to the
  -- bedroom. Check proximity BEFORE followTrail so we stop trailing into the
  -- blocked tile. Verified end-to-end from pokey_free (probe_knock reaches 80).
  local ddx = math.abs(px - 0x0A60) + math.abs(py - 0x0158)
  if ddx <= 0x20 then
    if (frame() % 20) < 4 then pad.press("A") else pad.press("Up") end
    return
  end
  if followRoute("crater_to_onett") then return end
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
