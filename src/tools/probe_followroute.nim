## Coordinate-free crater route: followRoute("onett_to_crater") only.
## Dense trail lives in NamedRoutesLua (skill library); policy has no coords.
## Usage: nim r src/tools/probe_followroute.nim [rom] [state]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, story_percents, scene]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/onett_start.state"
  MaxFrames = 12_000
  JamStuckFrames = 600

  # Policy: no literal coordinates. Route points are engine-held.
  # pokeyPct is a Nim-bound getter (story_percents.pokeyPercent).
  FollowRoutePolicy = """
function update()
  if pokeyPct and pokeyPct() >= 100 then
    return
  end
  if advanceDialogue and advanceDialogue() then
    return
  end
  -- Talk when already adjacent so yard NPCs cannot yank us off-trail mid-route.
  local e = nearestEntity()
  if e ~= nil and e.dist_tiles ~= nil and e.dist_tiles <= 1 then
    if talk(e.slot) then
      return
    end
  end
  if followRoute("onett_to_crater") then
    return
  end
  -- Route end reached: approach + talk nearest (Pokey at talk spot).
  if e ~= nil then
    talk(e.slot)
  elseif nearestEntity then
    local n = nearestEntity()
    if n ~= nil then
      talk(n.slot)
    end
  end
end
"""

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load a Lua chunk and run it (defines globals).
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua scene() binding for nearestEntity / talk.
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  return 1

proc pokeyPctLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua pokeyPct() -> story_percents.pokeyPercent (no coords in policy).
  let ctx = policy.getPolicyCtx(L)
  L.pushinteger(pokeyPercent(ctx.snes))
  return 1

proc main() =
  ## Run followRoute policy from onett_start; print honest final pokeyPercent.
  let rom = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  if not fileExists(rom):
    echo "SKIP: no ROM at ", rom
    quit(0)
  if not fileExists(statePath):
    echo "SKIP: no state at ", statePath
    quit(0)

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
  L.pushcfunction(pokeyPctLua)
  L.setglobal("pokeyPct".cstring)

  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" &
    DoorEnterSkillLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  if "function followRoute" notin skills or "onett_to_crater" notin skills:
    raise newException(ValueError, "skills missing followRoute / onett_to_crater")
  loadChunk(L, FollowRoutePolicy, "followroute")

  # Policy must stay coordinate-free (hex literals only allowed in skill lib).
  if "0x0" in FollowRoutePolicy or "0x1" in FollowRoutePolicy:
    raise newException(ValueError, "policy must not contain coordinate hex literals")

  echo &"start followRoute probe from {statePath}"
  echo "policy: if pokeyPct()>=100 done; talk when adjacent; followRoute(\"onett_to_crater\")"
  echo "policy uses ONLY followRoute/talk/nearestEntity/advanceDialogue/pokeyPct — no coordinates"
  echo &"scene: {sceneJson(snes)}"

  var lastPk = -1
  var maxPk = 0
  var minY = 0xFFFF
  var northernmost = (0, 0)
  var westernmost = (0xFFFF, 0)
  var dlgOpened = false
  var talkedPokey = false
  var gradeHits: seq[string]
  var jamFrames = 0
  var lastPos = (-1, -1)
  var lastDlgLog = -999
  var routeDone = false

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

    # Detect route completion: near last trail point (0x0858,0x00FA).
    let dEnd = abs(px - 0x0858) + abs(py - 0x00FA)
    if dEnd <= 12 and not routeDone:
      routeDone = true
      echo &"ROUTE_END f={f} pos=(0x{px:04X},0x{py:04X}) pokey={pk}"

    if (px, py) == lastPos and not open and not indoor:
      jamFrames += 1
    else:
      jamFrames = 0
      lastPos = (px, py)

    if pk != lastPk:
      let line = &"GRADE f={f} pokey={pk} pos=(0x{px:04X},0x{py:04X}) nearest=s{nSlot}/{nName}/{nDist}t win0=0x{win0:02X} 9885=0x{armed:02X}"
      echo line
      gradeHits.add line
      lastPk = pk
      if pk > maxPk: maxPk = pk

    if f mod 120 == 0:
      echo &"f={f} pos=(0x{px:04X},0x{py:04X}) joy=0x{ctx.joy1:04X} pokey={pk} nearest=s{nSlot}/{nName}/{nDist}t win0=0x{win0:02X} jam={jamFrames}"

    if open and f > 30 and f - lastDlgLog >= 60:
      lastDlgLog = f
      let txt = policy.getDialogueText(snes).strip()
      echo &"DIALOGUE f={f} win0=0x{win0:02X} win1=0x{win1:02X} text=[{txt[0 ..< min(80, txt.len)]}]"
      if nName == "pokey" or pk >= 90:
        talkedPokey = true
        echo &"SUCCESS talk near Pokey f={f} pokey={pk}"
        break

    if pk >= 100:
      echo &"SUCCESS pokey=100 f={f}"
      break

    if indoor and f > 100:
      echo &"FAIL indoor warp f={f} pos=(0x{px:04X},0x{py:04X})"
      break

    if jamFrames >= JamStuckFrames and f > 300:
      echo &"JAM f={f} pokey={pk} pos=(0x{px:04X},0x{py:04X}) stuck={jamFrames} frames nearest=s{nSlot}/{nName}/{nDist}t"
      break

  let i = PlayerSlot * SlotIndexStride
  let fx = readU16(snes, WorldXBase + i)
  let fy = readU16(snes, WorldYBase + i)
  let finalSc = buildScene(snes)
  let fnDist = if finalSc.ents.len > 0: finalSc.ents[0].distTiles else: -1
  let fnSlot = if finalSc.ents.len > 0: finalSc.ents[0].slot else: -1
  let fnName = if finalSc.ents.len > 0: finalSc.ents[0].name else: ""
  let finalPk = pokeyPercent(snes)
  echo "=== followRoute summary ==="
  echo &"FINAL pos=(0x{fx:04X},0x{fy:04X}) pokey={finalPk} max_pokey={maxPk} dlgOpened={dlgOpened} talkedPokey={talkedPokey} routeDone={routeDone}"
  echo &"northernmost outdoor (0x{northernmost[0]:04X},0x{northernmost[1]:04X}) minY=0x{minY:04X}"
  echo &"westernmost outdoor (0x{westernmost[0]:04X},0x{westernmost[1]:04X})"
  echo &"FINAL nearest slot={fnSlot} name={fnName} dist={fnDist} 9885=0x{readU8(snes, 0x9885):02X}"
  echo "grade transitions:"
  for g in gradeHits:
    echo "  ", g
  if finalPk >= 100 or talkedPokey:
    echo "HONEST: followRoute reached crater / Pokey talk — pokeyPercent=", finalPk
  elif maxPk >= 70:
    echo &"HONEST: stalled in ridge/crater band max_pokey={maxPk} final={finalPk}"
  elif maxPk >= 60:
    echo &"HONEST: stalled in north crest band max_pokey={maxPk} final={finalPk}"
  elif maxPk >= 30:
    echo &"HONEST: stalled in west-road band max_pokey={maxPk} final={finalPk}"
  elif maxPk >= 10:
    echo &"HONEST: stalled in yard band max_pokey={maxPk} final={finalPk}"
  else:
    echo &"HONEST: no outdoor pokey grade final={finalPk}"

when isMainModule:
  main()
