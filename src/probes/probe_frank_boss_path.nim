## Day-1 Frank / arcade path past frank 80 geography: door-hunt near downtown,
## battle flags, indoor transitions. Captures SCRATCH-friendly metric lines.
## checkpoints.md: Frank / Frankystein — next referee after frank_pct=80 soft.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Downtown = "bin/states/llm/frank_downtown.state"
  Giant = "bin/states/llm/giant_approach.state"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc battleFlag(snes: SnesBus): int =
  ## $4DBA battle flag (perception / battle_fields).
  readU8(snes, 0x4DBA)

proc dumpGrade(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  let sj = scene.sceneJson(snes)
  let head = if sj.len > 280: sj[0 ..< 280] & "..." else: sj
  echo fmt"GRADE {tag} pos=(0x{px:04X},0x{py:04X}) fr={frankPercent(snes)} gs={giantStepPercent(snes)} cs={captainStrongPercent(snes)} battle=$4DBA={battleFlag(snes):02X} 99F2={readU8(snes,0x99F2):02X}"
  echo "SCENE ", tag, " ", head
  echo "SPINE ", checkpointSpineLine(snes)

proc runPolicy(snes: SnesBus; cpu: var Cpu; pol: string; frames: int; label: string): tuple[maxFr, maxGs, maxCs, maxBattle: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua &
    "\n" & AdvanceDialogueSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, pol, label)
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  result.maxCs = captainStrongPercent(snes)
  result.maxBattle = battleFlag(snes)
  let i = PlayerSlot * SlotIndexStride
  var stuck = 0
  var prevX = readU16(snes, WorldXBase + i)
  var prevY = readU16(snes, WorldYBase + i)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # Hold knock for outdoor ladders on night fixtures.
    if readU8(snes, KnockCompleteOff) == KnockCompleteVal:
      discard
    else:
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    let cs = captainStrongPercent(snes)
    let bf = battleFlag(snes)
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if cs > result.maxCs: result.maxCs = cs
    if bf > result.maxBattle: result.maxBattle = bf
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    if abs(px - prevX) + abs(py - prevY) <= 1:
      stuck.inc
    else:
      stuck = 0
    prevX = px
    prevY = py
    if f mod 1500 == 0 or bf != 0:
      echo fmt"  {label} f={f} pos=(0x{px:04X},0x{py:04X}) fr={fr} gs={gs} cs={cs} battle={bf:02X} stuck={stuck}"
    if stuck > 400 and f > 500:
      echo fmt"STUCK_DETECTED {label} counter={stuck} — pad replan (B+menu clear)"
      # Soft recovery: clear joy, A/B chatter for dialogue
      for _ in 1 .. 30:
        snes.joy1 = 0x8000  # B
        policy.stepOneFrame(snes, cpu, img)
      stuck = 0
  echo fmt"FINAL {label} max_fr={result.maxFr} max_gs={result.maxGs} max_cs={result.maxCs} max_battle={result.maxBattle}"

proc loadBase(path: string): tuple[snes: SnesBus, cpu: Cpu] =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  (snes, cpu)

proc main() =
  echo "=== FRANK BOSS PATH PROBE (checkpoints.md Frank/Frankystein) ==="
  doAssert fileExists(Rom)
  let startPath =
    if fileExists(Downtown): Downtown
    elif fileExists(Giant): Giant
    elif fileExists(Outdoor): Outdoor
    else: ""
  doAssert startPath.len > 0, "need frank_downtown / giant / outdoor"
  echo "START_PATH=", startPath

  # Leg A: explore south/west for arcade door candidates (door enter thrash)
  block:
    var (snes, cpu) = loadBase(startPath)
    dumpGrade(snes, "start")
    # Arcade hunt: south commercial + west toward police, try A on walls/doors.
    let pol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  local f = frame() % 240
  -- Prefer deep south commercial (frank 80 band), then west toward police/arcade.
  if py < 0x0280 then
    pad.press("Down")
    if f < 40 then pad.press("Left") end
    return
  end
  if py < 0x02C0 then
    pad.press("Down")
    if f < 80 then pad.press("Left") elseif f < 120 then pad.press("Right") end
    return
  end
  -- At south edge: sweep west for arcade / police buildings; A on contact.
  if px > 0x0880 then
    pad.press("Left")
    if (f % 16) < 4 then pad.press("A") end
    if (f % 48) < 8 then pad.press("Up") end
    return
  end
  -- West pocket: nudge N/S + talk
  if f < 80 then pad.press("Up")
  elseif f < 140 then pad.press("Down")
  elseif f < 180 then pad.press("Right")
  else pad.press("A") end
  if (f % 20) < 3 then pad.press("A") end
end
"""
    let r = runPolicy(snes, cpu, pol, 9000, "arcade_hunt")
    dumpGrade(snes, "after_arcade_hunt")
    if r.maxFr >= 80 or r.maxCs >= 40:
      writeFile("bin/states/llm/frank_arcade_attempt.state", cast[string](serializeState(snes, cpu)))
      echo "WROTE frank_arcade_attempt.state"

  # Leg B: continuous frank_downtown → giant west → captain south (product handoff)
  block:
    var (snes, cpu) = loadBase(startPath)
    let giantPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py < 0x0280 then pad.press("Down"); return end
  -- giant 60 = west of deep-south
  if px > 0x0940 then pad.press("Left"); return end
  pad.press("Left")
  if (frame() % 40) < 12 then pad.press("Down") end
end
"""
    let g = runPolicy(snes, cpu, giantPol, 5000, "giant_west")
    dumpGrade(snes, "after_giant")
    let capPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py < 0x02A0 then
    pad.press("Down")
    if (frame() % 36) < 10 then pad.press("Left") end
    return
  end
  pad.press("Down")
  if (frame() % 50) < 15 then pad.press("Left") end
end
"""
    let c = runPolicy(snes, cpu, capPol, 4000, "captain_south")
    dumpGrade(snes, "after_captain")
    echo fmt"HANDOFF max_fr={max(g.maxFr,c.maxFr)} max_gs={max(g.maxGs,c.maxGs)} max_cs={max(g.maxCs,c.maxCs)}"
    if c.maxCs >= 50:
      writeFile("bin/states/llm/captain_from_frank_boss.path.state", cast[string](serializeState(snes, cpu)))
      # avoid weird filename
      writeFile("bin/states/llm/captain_from_frank_probe.state", cast[string](serializeState(snes, cpu)))
      echo "WROTE captain_from_frank_probe.state"

  # Leg C: outdoor → frank 80 continuous (product day-1)
  if fileExists(Outdoor):
    var (snes, cpu) = loadBase(Outdoor)
    dumpGrade(snes, "outdoor_start")
    let frankPol = """
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px < 0x09C0 then
    if followRoute and followRoute("crater_to_onett") then return end
    pad.press("Right"); return
  end
  if py >= 0x0280 then
    local f = frame() % 120
    if f < 50 then pad.press("Down")
    elseif f < 90 then pad.press("Left")
    else pad.press("Right") end
    return
  end
  if py >= 0x0240 then
    if walkTo then walkTo(0x09C0, 0x02A0) else pad.press("Down") end
    return
  end
  if followRoute and followRoute("onett_to_crater") then return end
  if walkTo then walkTo(0x09E0, 0x024E) else pad.press("Down") end
end
"""
    let r = runPolicy(snes, cpu, frankPol, 8000, "outdoor_to_frank80")
    dumpGrade(snes, "outdoor_frank_end")
    echo fmt"OUTDOOR_LEG max_fr={r.maxFr} max_gs={r.maxGs} max_cs={r.maxCs}"
    if r.maxFr >= 80:
      writeFile("bin/states/llm/frank_arcade.state", cast[string](serializeState(snes, cpu)))
      echo "WROTE frank_arcade.state (fr80 commercial band)"

  echo "OK probe_frank_boss_path"

when isMainModule:
  main()
