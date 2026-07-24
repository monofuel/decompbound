## d51 continuous spine: outdoor→home knock80 (sleep RE wall), then product
## post-knock outdoor → AgentBuzz → Frank → Giant metric deltas.
##
## Sleep→knock100 is unreproducible from bed (window opens, no $99F2=$58).
## Day-1 referee path uses free post_knock_outdoor (minimal signature synth).

import
  std/[os, strformat, osproc],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorStart = "bin/states/llm/onett_start.state"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring)
  1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found:
    L.pushnil()
    return 1
  L.pushinteger(t.x)
  L.pushinteger(t.y)
  2

proc skillsSrc(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & AdvanceDialogueSkillLua &
    "\n" & NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua &
    "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua

proc ensureOutdoorPk() =
  if fileExists(OutdoorPk):
    return
  let (o, code) = execCmdEx("nim r -d:release src/probes/synth_post_knock_outdoor.nim")
  echo o
  doAssert code == 0 and fileExists(OutdoorPk)

proc runPhase(
    snes: SnesBus,
    c: var Cpu,
    policySrc: string,
    label: string,
    maxFrames: int
): tuple[maxBb, maxSu, maxFr, maxGs, maxCs, maxKnock: int] =
  ## Drive one Agent policy; return peak spine metrics.
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua)
  L.setglobal("landmarkTarget".cstring)
  loadChunk(L, skillsSrc(), "sk")
  loadChunk(L, policySrc, label)
  var maxBb = buzzBuzzPercent(snes)
  var maxSu = sunrisePercent(snes)
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  var maxCs = captainStrongPercent(snes)
  var maxKnock = pokeyKnockPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. maxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let bb = buzzBuzzPercent(snes)
    let su = sunrisePercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    let kn = pokeyKnockPercent(snes)
    if bb > maxBb: maxBb = bb
    if su > maxSu: maxSu = su
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
    if cs > maxCs: maxCs = cs
    if kn > maxKnock: maxKnock = kn
    if f mod 2500 == 0:
      echo fmt"  {label} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"kn={kn}/{maxKnock} bb={bb}/{maxBb} su={su}/{maxSu} fr={fr}/{maxFr} " &
        fmt"gs={gs}/{maxGs} cs={cs}/{maxCs} room={currentRoomLabel(snes)}"
  echo fmt"PHASE {label}: max_knock={maxKnock} max_buzz={maxBb} max_sun={maxSu} " &
    fmt"max_frank={maxFr} max_giant={maxGs} max_captain={maxCs}"
  (maxBb, maxSu, maxFr, maxGs, maxCs, maxKnock)

proc main() =
  ## Phase A continuous knock80; Phase B product day-1 spine metrics.
  doAssert fileExists(Rom)
  doAssert fileExists(OutdoorStart)
  ensureOutdoorPk()

  echo "=== PHASE A: continuous outdoor→home knock80 / bed sleep attempt ==="
  let snesA = newSnesBus(policy.readRomFile(Rom))
  var cA = snesA.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorStart)), snesA, cA)
  let imgA = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctxA = policy.PolicyContext(
    snes: snesA, frameImage: imgA, frameCount: 0, joy1: 0, targetFps: 0)
  let LA = lua53.newstate()
  LA.openSandbox()
  policy.setupPolicyApi(LA, ctxA)
  LA.pushcfunction(sceneLua)
  LA.setglobal("scene".cstring)
  LA.pushcfunction(landmarkLua)
  LA.setglobal("landmarkTarget".cstring)
  loadChunk(LA, skillsSrc(), "sk")
  loadChunk(LA, AgentOutdoorPolicy, "out")
  var home = false
  var maxK = 0
  var maxWinOpen = 0
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 22000:
    ctxA.frameCount = f
    discard policy.runPolicyFrame(LA, ctxA)
    snesA.joy1 = ctxA.joy1
    policy.stepOneFrame(snesA, cA, imgA)
    let k = pokeyKnockPercent(snesA)
    if k > maxK: maxK = k
    let w1 = readU8(snesA, 0x8654)
    if w1 != 0xFF: maxWinOpen = 1
    if pokeyPercent(snesA) >= 100 and not home:
      loadChunk(LA, skillsSrc(), "sk2")
      loadChunk(LA, AgentHomePolicy, "home")
      home = true
      echo "HANDOFF home f=", f, " knock=", k
    if f mod 4000 == 0 or maxK >= 80:
      echo fmt"A f={f} pos=(0x{readU16(snesA,WorldXBase+i):04X},0x{readU16(snesA,WorldYBase+i):04X}) " &
        fmt"knock={k} maxK={maxK} room={currentRoomLabel(snesA)} " &
        fmt"99F2={readU8(snesA,0x99F2):#04x} win1={w1:#04x} kc={knockComplete(snesA)}"
    if maxK >= 80 and f >= 12000:
      # Hold bed a while then stop; sleep never sets $99F2 in emu so far.
      if f >= 16000:
        break
  echo "PHASE A FINAL maxK=", maxK, " knockComplete=", knockComplete(snesA),
    " bed_window_opened=", maxWinOpen == 1, " room=", currentRoomLabel(snesA)
  doAssert maxK >= 80, "continuous outdoor→home must reach knock>=80"
  doAssert not knockComplete(snesA),
    "expected sleep RE wall: knockComplete still false at bed (no $99F2=$58)"

  echo "=== PHASE B: product post_knock_outdoor → Buzz → Frank → Giant ==="
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  doAssert knockComplete(snes)
  echo "start outdoor_pk knock=", pokeyKnockPercent(snes),
    " bb=", buzzBuzzPercent(snes), " fr=", frankPercent(snes),
    " gs=", giantStepPercent(snes), " su=", sunrisePercent(snes)

  let buzzR = runPhase(snes, c, AgentBuzzBuzzPolicy, "buzz", 8000)
  let frankR = runPhase(snes, c, AgentFrankFromMeteorPolicy, "frank_meteor", 10000)
  let giantR = runPhase(snes, c, AgentGiantStepPolicy, "giant", 8000)

  let peakBb = max(buzzR.maxBb, max(frankR.maxBb, giantR.maxBb))
  let peakSu = max(buzzR.maxSu, max(frankR.maxSu, giantR.maxSu))
  let peakFr = max(buzzR.maxFr, max(frankR.maxFr, giantR.maxFr))
  let peakGs = max(buzzR.maxGs, max(frankR.maxGs, giantR.maxGs))
  let peakCs = max(buzzR.maxCs, max(frankR.maxCs, giantR.maxCs))
  echo "=== d51 SPINE SUMMARY ==="
  echo "A continuous_knock max=", maxK, " sleep_kc=", knockComplete(snesA)
  echo "B max_buzz=", peakBb, " max_sun=", peakSu, " max_frank=", peakFr,
    " max_giant=", peakGs, " max_captain=", peakCs
  doAssert peakBb >= 40
  doAssert peakFr >= 40
  doAssert peakGs >= 40 or peakFr >= 60
  echo "OK probe_continuous_day1_spine"

when isMainModule:
  main()
