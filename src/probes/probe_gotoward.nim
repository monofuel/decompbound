## Coordinate-free house->crater route via goToward("meteor_crater") + talk.
## Policy uses ONLY intent verbs (no literal coordinates). Start: onett_start.
## Usage: nim r -d:release src/probes/probe_gotoward.nim [rom] [state]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/onett_start.state"
  MaxFrames = 9000
  TalkNearTiles = 2

  # Coordinate-free policy: goToward by landmark NAME, talk when an NPC is near.
  # Exclusive branches — never call talk() and goToward() in the same frame
  # (both use navTo; dual press cancels the stick and freezes the player).
  GoTowardPolicy = """
function update()
  if advanceDialogue and advanceDialogue() then
    return
  end
  local e = nearestEntity()
  -- dist_tiles<=2 ≈ talk range; yard NPCs at 4+ tiles must not steal the route.
  if e ~= nil and e.dist_tiles ~= nil and e.dist_tiles <= 2 then
    talk(e.slot)
    return
  end
  goToward("meteor_crater")
end
"""

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load a Lua chunk and run it (defines globals).
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Lua scene() binding (same as llm_ai / probe_intent_nav).
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

proc main() =
  ## Run goToward policy from onett_start; print pokeyPercent over time.
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
  loadChunk(L, GoTowardPolicy, "gotoward")

  echo &"start goToward probe from {statePath}"
  echo &"scene: {sceneJson(snes)}"
  echo "policy uses ONLY goToward/talk/nearestEntity/advanceDialogue — no literal coordinates"
  block:
    let t = scene.landmarkTarget(snes, "meteor_crater")
    echo &"landmarkTarget meteor_crater found={t.found} (engine resolves; policy has no hex)"

  var lastPk = -1
  var maxPk = 0
  var minY = 0xFFFF
  var northernmost = (0, 0)
  var westernmost = (0xFFFF, 0)
  var dlgOpened = false
  var gradeHits: seq[string]

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

    if pk != lastPk:
      let line = &"GRADE f={f} pokey={pk} pos=(0x{px:04X},0x{py:04X}) nearest=s{nSlot}/{nName}/{nDist}t win0=0x{win0:02X} 9885=0x{armed:02X}"
      echo line
      gradeHits.add line
      lastPk = pk
      if pk > maxPk: maxPk = pk

    if f mod 120 == 0:
      echo &"f={f} pos=(0x{px:04X},0x{py:04X}) joy=0x{ctx.joy1:04X} pokey={pk} nearest=s{nSlot}/{nName}/{nDist}t win0=0x{win0:02X} indoor={indoor}"

    if open and f > 30:
      let txt = policy.getDialogueText(snes).strip()
      echo &"DIALOGUE f={f} win0=0x{win0:02X} win1=0x{win1:02X} text=[{txt[0 ..< min(80, txt.len)]}]"
      if pk >= 90 or (nName == "pokey" and nDist <= TalkNearTiles):
        echo &"SUCCESS talk near Pokey f={f} pokey={pk}"
        break

    if pk >= 100:
      echo &"SUCCESS pokey=100 f={f}"
      break

    if indoor and f > 100:
      echo &"FAIL indoor warp f={f} pos=(0x{px:04X},0x{py:04X})"
      break

  let i = PlayerSlot * SlotIndexStride
  let fx = readU16(snes, WorldXBase + i)
  let fy = readU16(snes, WorldYBase + i)
  let finalSc = buildScene(snes)
  let fnDist = if finalSc.ents.len > 0: finalSc.ents[0].distTiles else: -1
  let fnSlot = if finalSc.ents.len > 0: finalSc.ents[0].slot else: -1
  let fnName = if finalSc.ents.len > 0: finalSc.ents[0].name else: ""
  echo "=== goToward summary ==="
  echo &"FINAL pos=(0x{fx:04X},0x{fy:04X}) pokey={pokeyPercent(snes)} max_pokey={maxPk} dlgOpened={dlgOpened}"
  echo &"northernmost outdoor (0x{northernmost[0]:04X},0x{northernmost[1]:04X}) minY=0x{minY:04X}"
  echo &"westernmost outdoor (0x{westernmost[0]:04X},0x{westernmost[1]:04X})"
  echo &"FINAL nearest slot={fnSlot} name={fnName} dist={fnDist} 9885=0x{readU8(snes, 0x9885):02X}"
  echo "grade transitions:"
  for g in gradeHits:
    echo "  ", g
  if maxPk >= 100 or dlgOpened:
    echo "HONEST: coordinate-free goToward+talk reached Pokey / dialogue"
  elif maxPk >= 60:
    echo "HONEST: reached north crest band (60+); hill/ridge progress but not full talk"
  elif maxPk >= 30:
    echo "HONEST: west-road band (30); climb/jam may have stalled short of crest"
  elif maxPk >= 10:
    echo "HONEST: stayed yard-band (10) — navTo may have jammed (direct hill / blocked path)"
  else:
    echo "HONEST: no outdoor pokey grade"

when isMainModule:
  main()
