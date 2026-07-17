## Coordinate-free house->crater CHAIN: goToward landmarks in order + talk.
## Road -> hill -> ridge -> crater. No literal coordinates in the policy.
## Usage: nim r src/tools/probe_gotoward_chain.nim [rom] [state]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, story_percents, scene]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/onett_start.state"
  MaxFrames = 12000
  JamStuckFrames = 600

  # Chain policy: advance leg when scene landmark dist_tiles <= 2.
  # Exclusive branches — never talk() and goToward() in the same frame.
  # Talk only on ridge/crater legs: yard NPCs at dist<=2 steal the route
  # (verified: slot 4 "world record" kids loop forever if talk is unrestricted).
  # NO literal coordinates; engine resolves names via landmarkTarget/scene.
  ChainPolicy = """
_leg = 1
_LEGS = {"onett_road", "hill_climb", "crater_ridge", "meteor_crater"}

local function _chainLandmarkDist(name)
  local j = scene() or ""
  local body = j:match('"landmarks":%[([^%]]*)%]')
  if not body or body == "" then
    return nil
  end
  for nm, dist in body:gmatch('"name":"([^"]*)","dir":"[^"]*","dist_tiles":(%d+)') do
    if nm == name then
      return tonumber(dist)
    end
  end
  return nil
end

-- Parse nearest entity robustly (optional name field breaks nearestEntity gmatch).
local function _chainNearest()
  local j = scene() or ""
  local body = j:match('"nearby_entities":%[([^%]]*)%]')
  if not body or body == "" then
    return nil
  end
  local best = nil
  for obj in body:gmatch('{[^}]+}') do
    local slot = tonumber(obj:match('"slot":(%d+)'))
    local dist = tonumber(obj:match('"dist_tiles":(%d+)'))
    local name = obj:match('"name":"([^"]*)"') or ""
    if slot ~= nil and dist ~= nil then
      if best == nil or dist < best.dist_tiles then
        best = {slot = slot, dist_tiles = dist, name = name}
      end
    end
  end
  return best
end

function update()
  if advanceDialogue and advanceDialogue() then
    return
  end
  -- Advance legs when close to the current landmark (scene dist, not hex).
  while _leg <= #_LEGS do
    local d = _chainLandmarkDist(_LEGS[_leg])
    if d ~= nil and d <= 2 then
      _leg = _leg + 1
    else
      break
    end
  end
  if _leg > #_LEGS then
    _leg = #_LEGS
  end
  -- Talk only on ridge (3) / crater (4); yard talk steals the chain.
  local e = _chainNearest()
  if e ~= nil and e.dist_tiles ~= nil and e.dist_tiles <= 2 and _leg >= 3 then
    talk(e.slot)
    return
  end
  goToward(_LEGS[_leg])
end
"""

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load a Lua chunk and run it (defines globals).
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua scene() binding (same as llm_ai / probe_gotoward).
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  return 1

proc landmarkTargetLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua landmarkTarget(name) -> x, y or nil (engine map; no coords in policy).
  let ctx = policy.getPolicyCtx(L)
  let t = scene.landmarkTarget(ctx.snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  return 2

proc readLeg(L: lua53.PState): int =
  ## Read policy-global _leg (1-based index into the landmark chain).
  L.getglobal("_leg".cstring)
  result = L.toInteger(-1).int
  L.pop(1)

const
  LegNames = ["onett_road", "hill_climb", "crater_ridge", "meteor_crater"]

proc legName(leg: int): string =
  ## Human label for the current chain leg.
  if leg >= 1 and leg <= LegNames.len:
    LegNames[leg - 1]
  else:
    &"leg{leg}"

proc main() =
  ## Run goToward chain policy from onett_start; print pokey% and leg over time.
  let rom = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  let snes = newSnesBus(policy.readRomFile(rom))
  var c = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)

  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)
  L.pushcfunction(landmarkTargetLua)
  L.setglobal("landmarkTarget".cstring)

  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & DoorEnterSkillLua & "\n" &
    IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, ChainPolicy, "chain")

  echo &"start goToward CHAIN probe from {statePath}"
  echo &"scene: {sceneJson(snes)}"
  echo "policy: goToward chain onett_road -> hill_climb -> crater_ridge -> meteor_crater"
  echo "policy uses ONLY goToward/talk/scene/advanceDialogue — no literal coordinates"
  for nm in LegNames:
    let t = scene.landmarkTarget(snes, nm)
    echo &"landmarkTarget {nm} found={t.found} (engine resolves; policy has no hex)"

  var lastPk = -1
  var maxPk = 0
  var lastLeg = -1
  var minY = 0xFFFF
  var northernmost = (0, 0)
  var westernmost = (0xFFFF, 0)
  var dlgOpened = false
  var talkedPokey = false
  var gradeHits: seq[string]
  var legHits: seq[string]
  var jamFrames = 0
  var lastPos = (-1, -1)
  var lastDlgLog = -999

  for f in 0 ..< MaxFrames:
    ctx.frameCount = f
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0 and f mod 100 == 0:
      echo &"ERR f={f}: {err}"
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)

    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let pk = pokeyPercent(snes)
    let win0 = readU8(snes, 0x8650)
    let win1 = readU8(snes, 0x8654)
    let armed = readU8(snes, 0x9885)
    let indoor = px >= OutdoorMaxX
    let leg = readLeg(L)
    let sc = buildScene(snes)
    let nDist = if sc.ents.len > 0: sc.ents[0].distTiles else: -1
    let nSlot = if sc.ents.len > 0: sc.ents[0].slot else: -1
    let nName = if sc.ents.len > 0: sc.ents[0].name else: ""
    let open = win0 != 0xFF or win1 != 0xFF
    if open:
      dlgOpened = true

    if py < minY and not indoor:
      minY = py
      northernmost = (px, py)
    if px < westernmost[0] and not indoor:
      westernmost = (px, py)

    if (px, py) == lastPos and not open and not indoor:
      jamFrames += 1
    else:
      jamFrames = 0
      lastPos = (px, py)

    if leg != lastLeg:
      let line = &"LEG f={f} leg={leg}/{legName(leg)} pokey={pk} pos=(0x{px:04X},0x{py:04X})"
      echo line
      legHits.add line
      lastLeg = leg

    if pk != lastPk:
      let line = &"GRADE f={f} pokey={pk} leg={leg}/{legName(leg)} pos=(0x{px:04X},0x{py:04X}) nearest=s{nSlot}/{nName}/{nDist}t win0=0x{win0:02X} 9885=0x{armed:02X}"
      echo line
      gradeHits.add line
      lastPk = pk
      if pk > maxPk: maxPk = pk

    if f mod 120 == 0:
      var lmDist = -1
      for l in sc.landmarks:
        if l.name == legName(leg):
          lmDist = l.distTiles
          break
      echo &"f={f} pos=(0x{px:04X},0x{py:04X}) joy=0x{ctx.joy1:04X} pokey={pk} leg={leg}/{legName(leg)} lmDist={lmDist} nearest=s{nSlot}/{nName}/{nDist}t win0=0x{win0:02X} jam={jamFrames}"

    if open and f > 30 and f - lastDlgLog >= 60:
      lastDlgLog = f
      let txt = policy.getDialogueText(snes).strip()
      echo &"DIALOGUE f={f} win0=0x{win0:02X} win1=0x{win1:02X} text=[{txt[0 ..< min(80, txt.len)]}]"
      if nName == "pokey" or pk >= 90:
        talkedPokey = true
        echo &"SUCCESS talk near Pokey f={f} pokey={pk} leg={leg}"
        break

    if pk >= 100:
      echo &"SUCCESS pokey=100 f={f} leg={leg}"
      break

    if indoor and f > 100:
      echo &"FAIL indoor warp f={f} pos=(0x{px:04X},0x{py:04X}) leg={leg}"
      break

    # Honest jam detect: stuck ~10s with no position change on a leg.
    if jamFrames >= JamStuckFrames and f > 300:
      echo &"JAM f={f} leg={leg}/{legName(leg)} pokey={pk} pos=(0x{px:04X},0x{py:04X}) stuck={jamFrames} frames nearest=s{nSlot}/{nName}/{nDist}t"
      break

  let i = PlayerSlot * SlotIndexStride
  let fx = readU16(snes, WorldXBase + i)
  let fy = readU16(snes, WorldYBase + i)
  let finalLeg = readLeg(L)
  let finalSc = buildScene(snes)
  let fnDist = if finalSc.ents.len > 0: finalSc.ents[0].distTiles else: -1
  let fnSlot = if finalSc.ents.len > 0: finalSc.ents[0].slot else: -1
  let fnName = if finalSc.ents.len > 0: finalSc.ents[0].name else: ""
  let finalPk = pokeyPercent(snes)
  echo "=== goToward CHAIN summary ==="
  echo &"FINAL pos=(0x{fx:04X},0x{fy:04X}) pokey={finalPk} max_pokey={maxPk} leg={finalLeg}/{legName(finalLeg)} dlgOpened={dlgOpened} talkedPokey={talkedPokey}"
  echo &"northernmost outdoor (0x{northernmost[0]:04X},0x{northernmost[1]:04X}) minY=0x{minY:04X}"
  echo &"westernmost outdoor (0x{westernmost[0]:04X},0x{westernmost[1]:04X})"
  echo &"FINAL nearest slot={fnSlot} name={fnName} dist={fnDist} 9885=0x{readU8(snes, 0x9885):02X}"
  echo "leg transitions:"
  for g in legHits:
    echo "  ", g
  echo "grade transitions:"
  for g in gradeHits:
    echo "  ", g
  if finalPk >= 100 or talkedPokey:
    echo "HONEST: chain reached crater / Pokey talk — SUCCESS"
  elif maxPk >= 70:
    echo &"HONEST: chain jammed at leg={finalLeg}/{legName(finalLeg)} with max_pokey={maxPk} (ridge/crater band; not full talk)"
  elif maxPk >= 60:
    echo &"HONEST: chain jammed at leg={finalLeg}/{legName(finalLeg)} with max_pokey={maxPk} (north crest band)"
  elif maxPk >= 30:
    echo &"HONEST: chain jammed at leg={finalLeg}/{legName(finalLeg)} with max_pokey={maxPk} (west-road band)"
  elif maxPk >= 10:
    echo &"HONEST: chain jammed at leg={finalLeg}/{legName(finalLeg)} with max_pokey={maxPk} (yard band)"
  else:
    echo "HONEST: no outdoor pokey grade"

when isMainModule:
  main()
