## Demo intent-level nav: approach/talk nearest entity from pokey_free with no
## hardcoded coordinates in the Lua policy. Mirrors probe_pokey_policy harness.
## Usage: nim r -d:release src/probes/probe_intent_nav.nim [rom] [state]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/pokey_free.state"
  MaxFrames = 2400

  # Coordinate-free policy: only intent verbs + scene perception.
  IntentPolicy = """
function update()
  if advanceDialogue and advanceDialogue() then
    return
  end
  local e = nearestEntity()
  if e == nil then
    return
  end
  -- Prefer talk(nearest); approach("N") also works when Pokey is north.
  if talk(e.slot) then
    return
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
  ## Lua scene() binding (same as llm_ai; not in setupPolicyApi to avoid cycles).
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  return 1

proc main() =
  ## Run intent-nav policy from pokey_free; print grades + dialogue open.
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

  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & DoorEnterSkillLua & "\n" &
    IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, IntentPolicy, "intent")

  echo &"start intent-nav from {statePath}"
  echo &"scene: {sceneJson(snes)}"
  echo "policy uses ONLY nearestEntity/talk/approach — no literal coordinates"

  var lastPk = -1
  var maxPk = 0
  var lastWin = -1
  var dlgOpened = false
  var gradeHits: seq[string]
  var nearestStart = ""

  block:
    let e0 = buildScene(snes)
    if e0.ents.len > 0:
      nearestStart = &"slot={e0.ents[0].slot} dir={e0.ents[0].dir} dist={e0.ents[0].distTiles}"
    else:
      nearestStart = "(none)"
  echo &"nearest at start: {nearestStart}"

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
    let sc = buildScene(snes)
    let nDist = if sc.ents.len > 0: sc.ents[0].distTiles else: -1
    let nSlot = if sc.ents.len > 0: sc.ents[0].slot else: -1
    let nDir = if sc.ents.len > 0: sc.ents[0].dir else: "-"
    let open = win0 != 0xFF or win1 != 0xFF
    if open:
      dlgOpened = true

    if pk != lastPk:
      let line = &"GRADE f={f} pokey={pk} pos=(0x{px:04X},0x{py:04X}) nearest=s{nSlot}/{nDir}/{nDist}t win0=0x{win0:02X} win1=0x{win1:02X} 9885=0x{armed:02X}"
      echo line
      gradeHits.add line
      lastPk = pk
      if pk > maxPk: maxPk = pk

    if open and (win0 != lastWin or win1 != lastWin):
      let txt = policy.getDialogueText(snes).strip()
      echo &"DIALOGUE f={f} win0=0x{win0:02X} win1=0x{win1:02X} text=[{txt[0 ..< min(80, txt.len)]}]"
      lastWin = win0

    if f mod 120 == 0:
      echo &"f={f} pos=(0x{px:04X},0x{py:04X}) joy=0x{ctx.joy1:04X} pokey={pk} nearest=s{nSlot}/{nDir}/{nDist}t win0=0x{win0:02X} win1=0x{win1:02X}"

    # Early success: dialogue window opened (talk), or grade already maxed after approach.
    if dlgOpened and f > 30:
      echo &"SUCCESS dialogue open f={f} pokey={pk} dlgOpened={dlgOpened}"
      break
    if pk >= 100 and f > 200 and not dlgOpened:
      # Keep trying A for a bit after grade max; don't stop instantly on adj-only 100.
      discard

  let i = PlayerSlot * SlotIndexStride
  let fx = readU16(snes, WorldXBase + i)
  let fy = readU16(snes, WorldYBase + i)
  let finalSc = buildScene(snes)
  let fnDist = if finalSc.ents.len > 0: finalSc.ents[0].distTiles else: -1
  let fnSlot = if finalSc.ents.len > 0: finalSc.ents[0].slot else: -1
  echo "=== intent-nav summary ==="
  echo &"FINAL pos=(0x{fx:04X},0x{fy:04X}) pokey={pokeyPercent(snes)} max_pokey={maxPk} dlgOpened={dlgOpened}"
  echo &"FINAL nearest slot={fnSlot} dist={fnDist} 9885=0x{readU8(snes, 0x9885):02X} win0=0x{readU8(snes, 0x8650):02X} win1=0x{readU8(snes, 0x8654):02X}"
  echo "grade transitions:"
  for g in gradeHits:
    echo "  ", g
  if dlgOpened or maxPk >= 90:
    echo "HONEST: intent verbs reached / talked nearest entity (Pokey) without policy coordinates"
  else:
    echo "HONEST: did not open dialogue or climb pokey grade — check approach/talk"

when isMainModule:
  main()
