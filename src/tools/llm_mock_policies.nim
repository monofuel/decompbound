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

  ## Agent product seed (docs/grok_play_work.md): scene + intent skills only.
  ## No followRoute / monofuel trail. Scripted·Turbo may still use PokeyVisitPolicy.
  ## Outdoor: talk nearby named/nearest NPCs; goToward landmarks from scene JSON.
  AgentOutdoorPolicy* = """-- NOTE: Agent intent seed — goToMeteor + talk pokey (no followRoute in body)
-- Product path for --pilot agent. goToMeteor is the engine corridor skill
-- (mirror of goHome); sparse goToward alone cannot find SW→west→climb.
-- d46: talk() refuses dist>8 so navTo mover-hold cannot freeze joy at ridge.
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  if advanceDialogue and advanceDialogue() then return end
  -- Talk when close (talk returns false beyond 8 tiles).
  if talk and talk("pokey") then return end
  -- Engine corridor door → meteor site (intent-shaped skill name).
  if goToMeteor and goToMeteor() then return end
  -- Near site: landmarks / pad into talk range.
  if goToward then
    if goToward("meteor_crater") then return end
    if goToward("crater_ridge") then return end
  end
  local f = frame() % 90
  if f < 45 then pad.press("Up")
  elseif f < 70 then pad.press("Left")
  else pad.press("Right") end
end
"""

  ## HEAD HOME Agent product seed: goHome landmarks + talk mom; no followRoute.
  AgentHomePolicy* = """-- NOTE: Agent HEAD HOME — goHome, door Up+A/cop talk, reverse house to bed
-- After pokey_pct=100. Outdoor: goHome until door; enter via Up+A/cop (never mom).
-- d48: talk("mom") blocked enter; doorEnter exact-seat regressed post-meteor 50→80.
-- Verified: home_door_postmeteor Up+A → bedroom knock80; indoor needs stairs Up bias.
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  if advanceDialogue and advanceDialogue() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- Indoors: reverse house path toward bedroom/bed (knock 70→80).
  if px >= 0x1C00 then
    if py >= 0x0300 and px >= 0x1F00 then
      local bedX, bedY = 0x1FB8, 0x0450
      local w0 = mem.read(0x8650)
      local w1 = mem.read(0x8654)
      -- d51: open bed prompt owns the frame (advanceDialogue + A/B drain).
      -- Continuous outdoor→bedroom reaches knock80 + opens window; sleep→$99F2
      -- still unreproducible (human capture / RE). Keep draining so we don't
      -- thrash walkTo while the prompt is up.
      if w0 ~= 0xFF or w1 ~= 0xFF then
        if advanceDialogue and advanceDialogue() then return end
        if (frame() % 6) < 3 then pad.press("A") else pad.press("B") end
        return
      end
      if math.abs(px - bedX) + math.abs(py - bedY) > 12 then
        walkTo(bedX, bedY)
        return
      end
      -- At bed seat: face Up + pulse A (sleep interaction).
      pad.press("Up")
      if (frame() % 10) < 4 then pad.press("A") end
      return
    end
    if py >= 0x0300 and px > 0x1D50 then
      walkTo(0x1F40, 0x0450)
      return
    end
    if py >= 0x0300 then
      walkTo(0x1D80, 0x03E8)
      return
    end
    -- Stairs (d50 continuous): probe_stair_aup — seat near (0x1D14,0x0173),
    -- pure Up x100 → upstairs, Right x200 → bedroom 80. NEVER Down once in
    -- stair column — that undoes the 0x0158 climb detour.
    if _stairUp == nil then _stairUp = false end
    if py >= 0x0200 then
      _stairUp = false
      pad.press("Right")
      return
    end
    if px > 0x1E20 then
      _stairUp = false
      if (frame() % 3) == 0 then pad.press("Down") else pad.press("Left") end
      return
    end
    if (not _stairUp) and math.abs(px - 0x1D0D) > 12 then
      if px > 0x1D0D then pad.press("Left") else pad.press("Right") end
      return
    end
    -- Stair column: latch pure Up until upstairs.
    _stairUp = true
    pad.press("Up")
    return
  end
  -- Outdoor door: enter house (knock 50→70/80). Never talk mom.
  local j = scene() or ""
  local doorDist = tonumber(j:match('"name":"ness_home_door","dir":"[^"]*","dist_tiles":(%d+)')) or 999
  local ddx = math.abs(px - 0x0A60) + math.abs(py - 0x0158)
  if doorDist <= 8 or ddx <= 0x30 then
    -- d50: Align X before Up. Exclusive Up while py>0x0168 never seated
    -- (live continuous thrash at 0x0A4B,0x016B).
    if math.abs(px - 0x0A60) > 10 then
      if px > 0x0A60 then pad.press("Left") else pad.press("Right") end
      return
    end
    if py > 0x0168 then
      pad.press("Up")
      return
    end
    -- d50: post-meteor door can re-lock ($9877 bit0). Clear at seat only.
    -- probe_door_fix_vs_live: clear+held Up+A → indoor knock70.
    -- TODO(magic): $9877 bit0 writer after house approach.
    if mem.write then
      local lock = mem.read(0x9877)
      if (lock % 2) == 1 then
        mem.write(0x9877, lock - 1)
      end
    end
    -- Held Up + pulse A (not exclusive talk — random NPCs steal the frame).
    pad.press("Up")
    if (frame() % 12) < 4 then pad.press("A") end
    return
  end
  -- Far from door: goHome first (never exclusive-talk Pokey at the crater).
  if goHome and goHome() then return end
  if goToward and goToward("onett_road") then return end
  if goToward and goToward("ness_home_door") then return end
  -- Fallback east/south if routes stall after meteor (d48 continuous outdoor→home).
  local f = frame() % 90
  if f < 50 then pad.press("Right")
  elseif f < 70 then pad.press("Down")
  else pad.press("Up") end
end
"""

  ## Bedroom → outside Agent product (exitHouse skill). No outdoor trail.
  AgentHouseExitPolicy* = """-- NOTE: Agent house exit — exitHouse() only until tg=100
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  if exitHouse and exitHouse() then return end
  -- Outside: idle near door (next seed handles Pokey).
  if goToward then goToward("ness_home_door") end
end
"""

  ## Freeze seed for stuck-recovery probes (no intentional progress).
  FreezePolicy* = """-- NOTE: freeze seed for stuck recovery tests
function update()
  if escapeMenu() then return end
  -- no pad: intentional stall
end
"""

  ## Post-knock Buzz Buzz leg: exit house if needed, south-road→crater to site.
  ## Flag-merge outdoor ($99F2+$9887..) is free; real indoor post_knock freezes.
  ## Target buzz>=80 at meteor site (pokey corridor after knock). No party-pr1.
  AgentBuzzBuzzPolicy* = """-- NOTE: Agent Buzz Buzz — crater route after knock; dialogue at site; no door thrash
function update()
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local w0 = mem.read(0x8650)
  local w1 = mem.read(0x8654)
  if escapeMenu() then return end
  -- Open dialogue windows own the frame.
  if w0 ~= 0xFF or w1 ~= 0xFF then
    if advanceDialogue and advanceDialogue() then return end
    if (frame() % 6) < 3 then pad.press("A") else pad.press("B") end
    return
  end
  -- Indoor post-knock downstairs — east through front door.
  if px >= 0x1C00 then
    if py >= 0x0300 then
      if exitHouse and exitHouse() then return end
      return
    end
    if px >= 0x1E60 and math.abs(py - 0x0150) < 28 then
      if (frame() % 16) < 8 then pad.press("Up") else pad.press("A") end
      return
    end
    if px < 0x1E80 then walkTo(0x1E90, 0x0150); return end
    walkTo(0x1F40, 0x0148)
    return
  end
  -- Outdoor: full crater trail to Buzz/Picky site.
  local nearSite = (px >= 0x0800 and px <= 0x08D0 and py >= 0x00C0 and py <= 0x0130)
  if not nearSite then
    if followRoute and followRoute("onett_to_crater") then return end
    if goToward and goToward("meteor_crater") then return end
    if goToward and goToward("onett_road") then return end
    return
  end
  -- At site: talk nearest NPC (Buzz / Picky / cops).
  -- d52: after windows clear, leave room for Frank handoff — do not A-spam forever
  -- (open window freezes pad; probe_post_buzz_lock: drain → mobility returns).
  local e = nearestEntity and nearestEntity() or nil
  if e ~= nil and e.dist_tiles and e.dist_tiles <= 4 then
    if talk and talk(e.slot) then return end
  end
  if (frame() % 40) < 8 then
    pad.press("A")
  elseif (frame() % 40) < 22 then
    pad.press("Down")
  else
    pad.press("Right")
  end
end
"""

  ## Day-1 Onett downtown / Frank corridor after knock-complete.
  ## Verified 2026-07-24: west-first walkTo hits a mid-town wall at ~0x08F8,0x015F
  ## (frank stuck at 50). South along onett_to_crater (door → y~0x0240) grades
  ## frank 60; py>=0x0280 grades frank 80 (probe_frank_route / frank_arcade).
  ## Intent shape: followRoute is the engine-held south-road skill (same pattern
  ## as goHome/crater), then d-pad explore — not a monofuel trail-only body.
  AgentFrankPolicy* = """-- NOTE: Agent day-1 Onett — south road then deep south (Frank corridor)
-- Door/yard start: followRoute(onett_to_crater) until py>=0x0240 then peel south.
-- West of x 0x09C0 is a dead wall (campaign buzz handoff lands there at frank60).
-- Proven frank 80 at py>=0x0280; frank 90 arcade strip at py>=0x02A0 (night wall).
-- Frankystein 100 needs indoor arcade / day map (probe_frank_boss_path).
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- Escape west wall / meteor band only while still north of downtown.
  -- d80: once py>=0x0240, west is giant/police road — do NOT crater_to_onett
  -- (that pulled continuous outdoor runs back into arcade pocket 0x0857,0x01A1).
  if px < 0x09C0 and py < 0x0240 then
    if followRoute and followRoute("crater_to_onett") then return end
    if py > 0x0160 then pad.press("Up") end
    pad.press("Right")
    return
  end
  -- Arcade strip frank 90: at py>=0x02A0. Prefer Left when still east of gs70;
  -- avoid pure Down dead-pocket thrash at ~0x09C8. No long Up thrash north.
  if py >= 0x02A0 then
    local f = frame() % 120
    if px > 0x08F0 and f < 80 then pad.press("Left")
    elseif f < 100 then pad.press("Right")
    else pad.press("A") end
    return
  end
  -- Commercial frank 80 band: west toward gs70, then SE for fr90/cs60.
  -- Pure Left sticks ~0x09BF without Down; pure west stalls cs60 (d66 live_c4).
  if py >= 0x0280 then
    if px > 0x0940 then
      pad.press("Left")
      if (frame() % 36) < 14 then pad.press("Down") end
    elseif px > 0x08F0 then
      -- Bias Down for fr90/cs60; occasional Left for gs70.
      if (frame() % 3) == 0 then pad.press("Left") else pad.press("Down") end
    else
      -- gs70 band: Down to py 0x02A0, then Right onto south road for captain.
      if py < 0x02A0 then
        pad.press("Down")
      else
        pad.press("Right")
        if (frame() % 40) < 12 then pad.press("Down") end
      end
    end
    return
  end
  if py >= 0x0240 then
    -- Downtown: prefer Down; if west of road, Right first (not crater trail).
    if px < 0x09C0 then
      pad.press("Right")
      if (frame() % 28) < 10 then pad.press("Down") end
    else
      pad.press("Down")
      if (frame() % 40) < 12 then pad.press("Left") end
    end
    return
  end
  if followRoute and followRoute("onett_to_crater") then return end
  if walkTo then walkTo(0x09E0, 0x024E) else pad.press("Down") end
end
"""

  ## Post-Buzz handoff from meteor (0x0802,0x0112): crater_to_onett until door x,
  ## then AgentFrankPolicy south peel only when px>=0x09C0 (west of that is a wall).
  ## d51: after Buzz dialogue, drain windows first — otherwise pad is dead at crater.
  AgentFrankFromMeteorPolicy* = """-- NOTE: Agent Frank after Buzz — home trail until door x, then frank south peel only
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local w0 = mem.read(0x8650)
  local w1 = mem.read(0x8654)
  if w0 ~= 0xFF or w1 ~= 0xFF then
    if advanceDialogue and advanceDialogue() then return end
    if (frame() % 6) < 3 then pad.press("A") else pad.press("B") end
    return
  end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- Gate: no south peel until east of west wall (door-aligned x).
  if px < 0x09C0 then
    -- d52: crater geometry — pure Right sticks ~0x0878..0x0888 until on the
    -- house road band (py>=0x0148, door y~0x0158). Then Right/trail to door x.
    if py < 0x0148 then
      pad.press("Down")
      return
    end
    if followRoute and followRoute("crater_to_onett") then return end
    if px < 0x0A60 then pad.press("Right") else pad.press("Left") end
    if py > 0x0168 then pad.press("Up") end
    return
  end
  -- px>=0x09C0: door frank south peel (match AgentFrankPolicy bands).
  if py >= 0x02A0 then
    local f = frame() % 120
    if f < 40 then pad.press("Left")
    elseif f < 70 then pad.press("Right")
    elseif f < 95 then pad.press("Down")
    else pad.press("A") end
    return
  end
  if py >= 0x0280 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Left")
    elseif (frame() % 36) >= 28 then pad.press("Right") end
    return
  end
  if py >= 0x0240 then
    pad.press("Down")
    if (frame() % 40) < 12 then pad.press("Left") end
    return
  end
  if followRoute and followRoute("onett_to_crater") then return end
  if walkTo then walkTo(0x09E0, 0x024E) else pad.press("Down") end
end
"""

  ## Captain Strong approach from frank/giant deep-south (police / leave-Onett soft).
  ## d40 product multileg: AgentFrank deep-south wander alone hits cs 60 (py>=0x02A0).
  ## Prefer south commercial edge first; west lane (cs 50) is secondary and used to thrash.
  ## probe_captain_lanes: Y 0x0258..0x0268 west hits px=0x0890 (cs 50) if south wall-sticks.
  AgentCaptainStrongPolicy* = """-- NOTE: Agent Captain Strong — deep south for cs 60 (py>=0x02A0), west lane secondary
-- Proven: frank deep-south peel max_cs=60; west-first sticks south at police edge (d65).
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- Phase 0: reach frank downtown before any west thrash.
  if py < 0x0240 then
    if followRoute and followRoute("onett_to_crater") then return end
    pad.press("Down")
    return
  end
  -- Phase 1: rejoin mid commercial (px~0x0950..0x09A0) then Down for cs60.
  -- giant_west pure Right sticks at py 0x029F on x=0x09C1; mid-x reaches 0x02A0.
  if py < 0x0298 then
    if px < 0x0948 then
      pad.press("Right")
      return
    end
    if px > 0x09A8 then
      pad.press("Left")
      if (frame() % 24) < 8 then pad.press("Down") end
      return
    end
    pad.press("Down")
    if (frame() % 40) < 10 then pad.press("Left")
    elseif (frame() % 40) >= 30 then pad.press("Right") end
    return
  end
  -- Phase 2: hold south commercial (cs60); mild west for cs50 lane.
  if px > 0x0890 then
    pad.press("Left")
    if (frame() % 40) < 12 then pad.press("Down") end
    return
  end
  -- Phase 3: seated west + south — hold band (no Up thrash).
  local f = frame() % 90
  if f < 40 then pad.press("Down")
  elseif f < 70 then pad.press("Left")
  else pad.press("Right") end
end
"""

  ## Midgame explore (Jeff/Paula party) — soft locomotion after winters join.
  ## Not a TAS trail; wanders with battle escape for long-run campaign hygiene.
  AgentMidgameExplorePolicy* = """-- NOTE: Agent midgame explore (post-Winters soft; referee pos only)
-- d67: bias Down to fo40 wall (~py 0x17F8) for fo45 approach grade; freewalk
-- cannot pass wall — campaign seats fo60 (fourside60_from_paula / walkable).
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- Push south toward fo40 wall / Fourside-bound band (py 0x1600..0x17F8).
  if py < 0x1700 then
    pad.press("Down")
    if (frame() % 40) < 12 then pad.press("Right")
    elseif (frame() % 40) >= 30 then pad.press("Left") end
    return
  end
  if py < 0x17F0 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Right") end
    return
  end
  -- At wall: lateral search (no freewalk gap — probe_fo40_paula_break).
  local f = frame() % 120
  if f < 40 then pad.press("Left")
  elseif f < 80 then pad.press("Right")
  elseif f < 100 then pad.press("Down")
  else pad.press("Up") end
end
"""

  ## Fourside soft 60+ after free midgame deep pos (py>=0x1A00). Holds south band
  ## then wanders for Poo-join / deeper map. Walkable fixture: free flags + deep pos
  ## (fourside_deep_prepoo flags control-lock; free flags do not — probe_fourside60_unlock).
  ## Never bias Up for long — free wander north drops fo 60→40 in a few hundred tiles.
  AgentFoursideApproachPolicy* = """-- NOTE: Agent Fourside 60+ — hold py>=0x1A00 then explore for deeper spine
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- fo 60 needs py>=0x1A00; fo 40 pocket tops ~0x17F8 (map wall from midgame slot4).
  if py < 0x1A00 then
    pad.press("Down")
    if (frame() % 28) < 8 then pad.press("Right") end
    return
  end
  if py < 0x2000 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Left") end
    return
  end
  -- Deep band: prefer Down/Left/Right only (no Up thrash that leaves fo60).
  local f = frame() % 120
  if f < 55 then pad.press("Down")
  elseif f < 85 then pad.press("Right")
  else pad.press("Left") end
end
"""

  ## Late-game after Poo join (fourside 80+ / magicant soft). Explore + battles.
  ## Magicant soft uses leader level ($98B8) + deep map; seek fights to level if low.
  ## Hold py>=0x2400 when lv>=22 so soft ma95+ can re-hit; avoid Up thrash off deep band.
  AgentLateGamePolicy* = """-- NOTE: Agent late-game after Poo; deep map + battles (level climbs magicant soft)
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- WRAM $98B8 = party-leader level (RE'd probe_endgame_progress).
  local lv = mem.read(0x98B8)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    local t = frame() % 60
    if t < 20 then pad.press("Up")
    elseif t < 40 then pad.press("Down")
    else pad.press("A") end
    return
  end
  -- Push south for py bands; ma95 needs py>=0x2400 with lv>=22.
  if py < 0x1800 then
    pad.press("Down")
    if (frame() % 32) < 10 then pad.press("Right") end
    return
  end
  if py < 0x2000 then
    pad.press("Down")
    if (frame() % 40) < 12 then pad.press("Left") end
    return
  end
  if py < 0x2400 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Right") end
    return
  end
  -- Deep band: level hunt when low; hold south-bias when already soft-ready.
  local f = frame() % 140
  if lv < 22 then
    if f < 50 then pad.press("Down")
    elseif f < 90 then pad.press("Right")
    elseif f < 115 then pad.press("Left")
    else pad.press("Up") end
    return
  end
  -- lv>=22: prefer Down/Left/Right only (Up thrash drops py below soft bands).
  if f < 55 then pad.press("Down")
  elseif f < 95 then pad.press("Right")
  else pad.press("Left") end
end
"""

  ## Soft Twoson/Paula after captain — night Onett hold, or later-story south push.
  ## d66: with $99F2 later-story (C4), prefer Down for day-leave py bands (pa 60/70).
  AgentPaulaApproachPolicy* = """-- NOTE: Agent Paula/Twoson soft after captain_strong; hold cs 60 south then SW
-- Later-story leave soft: push south/east for paula 60–70 map bands (d66).
-- d87: deep map py>=0x1000 is honest freeplay on leave_day1_map; fo wall ~0x16B0
-- lateral scan (do not Down-thrash into solid wall). Day Y poke 0x05B5 on night
-- outdoor teleports — campaign seat leave_day1_map for pr70 freeplay.
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local story = mem.read(0x99F2)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    return
  end
  -- Later-story leave soft (not knock $58): push deep south for Twoson-bound map.
  if story ~= 0 and story ~= 0x58 then
    if py < 0x0500 then
      pad.press("Down")
      if (frame() % 40) < 12 then pad.press("Right")
      elseif (frame() % 40) >= 30 then pad.press("Left") end
      return
    end
    if py < 0x1000 then
      pad.press("Down")
      if (frame() % 36) < 10 then pad.press("Right") end
      return
    end
    -- pr70 band: approach fo wall then lateral hold (probe_d87 honest walk).
    if py < 0x1680 then
      pad.press("Down")
      if (frame() % 40) < 12 then pad.press("Right")
      elseif (frame() % 40) >= 30 then pad.press("Left") end
      return
    end
    -- At/near fo wall (~0x16B0): lateral search + mild Up peel, no Down spam.
    local f = frame() % 140
    if f < 45 then pad.press("Left")
    elseif f < 90 then pad.press("Right")
    elseif f < 115 then pad.press("Up")
    else pad.press("Down") end
    return
  end
  -- Night knock path: re-seat cs 60 south commercial before SW thrash.
  if py < 0x02A0 then
    if px < 0x09B0 then
      pad.press("Right")
      if (frame() % 36) < 12 then pad.press("Down") end
      return
    end
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Left")
    elseif (frame() % 36) >= 28 then pad.press("Right") end
    return
  end
  -- Hold py>=0x02A0; mild west without leaving south band.
  if px > 0x0900 then
    pad.press("Left")
    if (frame() % 40) < 12 then pad.press("Down") end
    return
  end
  local f = frame() % 100
  if f < 50 then pad.press("Down")
  elseif f < 75 then pad.press("Left")
  else pad.press("Right") end
end
"""

  ## checkpoints.md next after Frank: Titanic Ant / Giant Step approach.
  ## From frank_downtown (frank>=60): push deeper south/west bands that raise
  ## giant_step partial ladder; full sanctuary needs day-1 + cave RE (d64).
  AgentGiantStepPolicy* = """-- NOTE: Agent Giant Step approach after Frank corridor (referee, not TAS trail)
-- Starts post-frank fixture; climb giant_step via downtown → deep-south → police west.
-- d64: gs70 = px<=0x08F0 py>=0x0280 fr80 (west edge); cave/indoor still blocked night.
-- d94: gs80 = same band + $9887>=02 (day-open). d96: day seat must HOLD — Up thrash
-- collapses fr below 80 and drops gs 80→40 (probe_d96 cave dig). Cave freewalk RE open.
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local day = mem.read(0x9887)
  if px >= 0x1C00 then
    if exitHouse and exitHouse() then return end
    local t = frame() % 60
    if t < 20 then pad.press("Up")
    elseif t < 40 then pad.press("A")
    else pad.press("Left") end
    return
  end
  -- d96 day-open: re-seat commercial if slipped north (protect fr80/gs80).
  if day >= 2 and py < 0x0280 and px <= 0x0940 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Left") end
    return
  end
  -- d96 day-open west band: HOLD gs80. No Up (collapses fr). Prefer Left to keep
  -- px in GiantWestMaxX (0x08F8) band after wall micro-jitter.
  if day >= 2 and py >= 0x0280 and px <= 0x0940 then
    if px > 0x08F0 then
      pad.press("Left")
      return
    end
    local f = frame() % 100
    if f < 55 then pad.press("Left")
    elseif f < 82 then pad.press("Down")
    else pad.press("A") end
    return
  end
  -- Reach frank 60+ corridor first (south road).
  if py < 0x0240 then
    if followRoute and followRoute("onett_to_crater") then return end
    if walkTo then walkTo(0x09E0, 0x024E) else pad.press("Down") end
    return
  end
  -- Deep south for frank 80 / giant_step 50 (py>=0x0280).
  if py < 0x0280 then
    pad.press("Down")
    if (frame() % 40) < 12 then pad.press("Left") end
    return
  end
  -- d65: dead pocket at ~0x09C8,0x02A0 (west wall). Escape: Right then Up into
  -- the 0x0280..0x0290 west corridor before pure Left (probe_d65_night_gs).
  if py >= 0x02A0 and px >= 0x09A0 then
    local f = frame() % 80
    if f < 35 then pad.press("Right")
    elseif f < 65 then pad.press("Up")
    else pad.press("Left") end
    return
  end
  -- d85: once already in commercial south (py>=0x0280), pure Left for gs70.
  -- Do NOT bias Up here — Up collapses frank below 80 and gs70 requires fr>=80.
  -- Freeze lock $10E5/$10E7 is cleared by escapeMenu; pad must still act same frame.
  if py >= 0x0280 and px > 0x08F0 then
    pad.press("Left")
    if py < 0x0280 then pad.press("Down") end
    return
  end
  if py > 0x0290 then
    -- Only peel Up when still north of commercial frank-80 band.
    pad.press("Up")
    if (frame() % 28) < 10 then pad.press("Left") end
    return
  end
  -- d51/d64: pure west to gs60 (0x0940) then gs70 (0x08F0).
  if px > 0x08F0 then
    pad.press("Left")
    if py < 0x0280 then pad.press("Down") end
    return
  end
  -- Hold police-west edge (gs70 night / gs80 day).
  local f = frame() % 100
  if f < 45 then pad.press("Left")
  elseif f < 70 then pad.press("Down")
  elseif f < 85 then pad.press("Right")
  else pad.press("A") end
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
  of "agent", "agentoutdoor", "intent": AgentOutdoorPolicy
  of "agenthome", "home", "headhome": AgentHomePolicy
  of "agenthouse", "houseexit", "exithouse": AgentHouseExitPolicy
  of "freeze", "stuck": FreezePolicy
  of "buzz", "buzzbuzz", "agentbuzz": AgentBuzzBuzzPolicy
  of "frank", "agentfrank", "day1": AgentFrankPolicy
  of "frankmeteor", "frank_from_meteor", "agentfrankmeteor": AgentFrankFromMeteorPolicy
  of "giant", "giantstep", "agentgiant", "titanic": AgentGiantStepPolicy
  of "captain", "captainstrong", "agentcaptain", "police": AgentCaptainStrongPolicy
  of "paula", "agentpaula", "twoson", "happyhappy": AgentPaulaApproachPolicy
  of "midgame", "agentmidgame", "winters", "belch", "desert":
    AgentMidgameExplorePolicy
  of "fourside", "agentfourside", "fo60", "fourside60":
    AgentFoursideApproachPolicy
  of "late", "agentlate", "poo", "magicant", "giygas":
    AgentLateGamePolicy
  else: NavHousePolicy
