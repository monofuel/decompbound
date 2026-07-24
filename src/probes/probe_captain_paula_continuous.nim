## Continuous captain → live C4 leave soft → Paula soft ladder (night→later-story).
## checkpoints.md Captain Strong → Mr. Carpainter / Paula rescue soft.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Captain = "bin/states/llm/captain_approach.state"
  Giant = "bin/states/llm/giant_approach.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc dump(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"GRADE {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"cs={captainStrongPercent(snes)} pa={paulaRescuePercent(snes)} fr={frankPercent(snes)} " &
    fmt"gs={giantStepPercent(snes)} 99F2={readU8(snes,0x99F2):02X} later={laterStoryLeaveSoft(snes)}"

proc runPol(snes: SnesBus; cpu: var Cpu; pol, label: string; frames: int):
    tuple[maxCs, maxPa, maxFr, maxGs: int] =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua &
    "\n" & WinBattleSkillLua & "\n" & AdvanceDialogueSkillLua, "sk")
  loadChunk(L, pol, label)
  result.maxCs = captainStrongPercent(snes)
  result.maxPa = paulaRescuePercent(snes)
  result.maxFr = frankPercent(snes)
  result.maxGs = giantStepPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    if not laterStoryLeaveSoft(snes):
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let cs = captainStrongPercent(snes)
    let pa = paulaRescuePercent(snes)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if cs > result.maxCs: result.maxCs = cs
    if pa > result.maxPa: result.maxPa = pa
    if fr > result.maxFr: result.maxFr = fr
    if gs > result.maxGs: result.maxGs = gs
    if f mod 2000 == 0:
      echo fmt"  {label} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
        fmt"cs={cs} pa={pa} maxCs={result.maxCs} maxPa={result.maxPa}"
  echo fmt"FINAL {label} maxCs={result.maxCs} maxPa={result.maxPa} maxFr={result.maxFr} maxGs={result.maxGs}"

proc main() =
  echo "=== CAPTAIN→PAULA CONTINUOUS ==="
  doAssert fileExists(Rom)
  let start =
    if fileExists(Captain): Captain
    elif fileExists(Giant): Giant
    elif fileExists(Outdoor): Outdoor
    else: ""
  doAssert start.len > 0
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(start)), snes, cpu)
  if not laterStoryLeaveSoft(snes):
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  dump(snes, "start")

  if captainStrongPercent(snes) < 60:
    if frankPercent(snes) < 80 and fileExists(Outdoor) and start != Outdoor:
      # rebuild from outdoor if captain fixture weak
      discard
    let c = runPol(snes, cpu, AgentCaptainStrongPolicy, "captain", 8000)
    dump(snes, "after_captain")
    doAssert c.maxCs >= 50
  else:
    echo "captain already ", captainStrongPercent(snes)

  # Live C4 leave soft (product path — no party)
  if not laterStoryLeaveSoft(snes):
    applyLaterStoryLeaveSoft(snes)
    echo "APPLIED live C4 leave soft"
  dump(snes, "after_c4")
  let csC4 = captainStrongPercent(snes)
  let paC4 = paulaRescuePercent(snes)
  echo fmt"C4_GRADES cs={csC4} pa={paC4}"

  let p = runPol(snes, cpu, AgentPaulaApproachPolicy, "paula", 6000)
  dump(snes, "after_paula")
  echo fmt"HANDOFF maxCs={max(csC4,p.maxCs)} maxPa={max(paC4,p.maxPa)}"

  # Continuous outdoor full night→C4→paula if outdoor available
  if fileExists(Outdoor):
    let snes2 = newSnesBus(policy.readRomFile(Rom))
    var c2 = snes2.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Outdoor)), snes2, c2)
    snes2.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    dump(snes2, "full_start")
    discard runPol(snes2, c2, AgentFrankPolicy, "full_frank", 5000)
    discard runPol(snes2, c2, AgentGiantStepPolicy, "full_giant", 6000)
    discard runPol(snes2, c2, AgentCaptainStrongPolicy, "full_captain", 6000)
    dump(snes2, "full_pre_c4")
    if not laterStoryLeaveSoft(snes2):
      applyLaterStoryLeaveSoft(snes2)
    dump(snes2, "full_c4")
    discard runPol(snes2, c2, AgentPaulaApproachPolicy, "full_paula", 4000)
    dump(snes2, "full_end")
    echo "FULL_SPINE ", checkpointSpineLine(snes2)

  echo "OK probe_captain_paula_continuous"

when isMainModule: main()
