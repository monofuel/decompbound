## Smoke PokeyVisitPolicy north-hill route; log pos + pokey_pct grades.
## Usage: nim r -d:release src/tools/probe_pokey_policy.nim [rom] [state]
## Prefer onett_start; bedroom also works (NavHouse then switch).

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, llm_mock_policies, story_percents]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/onett_start.state"
  Bedroom = "bin/states/llm/bedroom.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load Lua.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc main() =
  ## Run pokey policy; print grade transitions with real (px,py).
  let rom = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath =
    if paramCount() >= 2: paramStr(2)
    elif fileExists(DefaultState): DefaultState
    else: Bedroom
  let snes = newSnesBus(policy.readRomFile(rom))
  var c = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)

  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  # doorEnter loaded but PokeyVisitPolicy must not call it
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & WinBattleSkillLua &
    "\n" & AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & DoorEnterSkillLua
  loadChunk(L, skills, "sk")

  var switched = false
  var lastPk = -1
  var maxPk = 0
  var minY = 0xFFFF
  var northernmost = (0, 0)
  var gradeHits: seq[string]

  if touchGrassPercent(snes) == 100:
    loadChunk(L, PokeyVisitPolicy, "pokey")
    switched = true
    echo &"start outdoor policy from {statePath}"
  else:
    loadChunk(L, NavHousePolicy, "nav")
    echo &"start NavHouse from {statePath}"

  for f in 0 ..< 6000:
    ctx.frameCount = f
    if touchGrassPercent(snes) == 100 and not switched:
      loadChunk(L, PokeyVisitPolicy, "pokey")
      switched = true
      echo &"SWITCH pokey f={f}"
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0 and f mod 200 == 0:
      echo &"ERR f={f}: {err}"
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)

    let i = PlayerSlot * SlotIndexStride
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let pk = pokeyPercent(snes)
    let win0 = readU8(snes, 0x8650)
    let indoor = px >= 0x1C00

    if py < minY and not indoor:
      minY = py
      northernmost = (px, py)

    if pk != lastPk:
      let line = &"GRADE f={f} pokey={pk} pos=(0x{px:04X},0x{py:04X}) indoor={indoor} win0=0x{win0:02X}"
      echo line
      gradeHits.add line
      lastPk = pk
      if pk > maxPk: maxPk = pk

    if f mod 120 == 0:
      echo &"f={f} pos=(0x{px:04X},0x{py:04X}) joy=0x{ctx.joy1:04X} tg={touchGrassPercent(snes)} pokey={pk} win0=0x{win0:02X} indoor={indoor}"

    # Abort if we wrongly entered a house (Minch/Ness) while outdoor-routing
    if switched and indoor and f > 100:
      echo &"FAIL indoor warp f={f} pos=(0x{px:04X},0x{py:04X}) — policy must stay outdoors"
      break

  let i = PlayerSlot * SlotIndexStride
  let fx = readU16(snes, WorldXBase + i)
  let fy = readU16(snes, WorldYBase + i)
  echo "=== smoke summary ==="
  echo &"FINAL pos=(0x{fx:04X},0x{fy:04X}) pokey={pokeyPercent(snes)} tg={touchGrassPercent(snes)} indoor={fx >= 0x1C00}"
  echo &"northernmost outdoor (0x{northernmost[0]:04X},0x{northernmost[1]:04X}) minY=0x{minY:04X} max_pokey={maxPk}"
  echo "grade transitions:"
  for g in gradeHits:
    echo "  ", g
  if fx >= 0x1C00:
    echo "HONEST: ended indoor — wrong route residual"
  elif maxPk >= 60:
    echo "HONEST: reached north crest grade (60); meteor/Pokey still TBD beyond Y~0x00B8 wall"
  elif maxPk >= 30:
    echo "HONEST: north hill approach (30); crest not held or walk stuck short of Y<=0x00C8"
  else:
    echo "HONEST: no north progress graded"

when isMainModule:
  main()
