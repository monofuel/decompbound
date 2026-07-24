## d85g: confirm clearing $10E5/$10E7 C0→00 unlocks walk; continuous product path.

import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  FreezePath = "bin/states/llm/south_freeze_fr90.state"
  # TODO(magic): $10E5/$10E7 — movement-block when C0; clear to 00 restores pad.
  # Found d85 bisect freeze vs free giant; both must clear for walk-like steps.
  FreezeLockA = 0x10E5
  FreezeLockB = 0x10E7
  FreezeLockVal = 0xC0
  FreezeClearVal = 0x00

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & IntentNavSkillLua

proc clearSouthFreeze(snes: SnesBus) =
  ## Clear RE'd south-commercial freeze locks if present.
  if readU8(snes, FreezeLockA) == FreezeLockVal:
    snes.bus.mem[0x7E0000 + FreezeLockA] = FreezeClearVal.uint8
  if readU8(snes, FreezeLockB) == FreezeLockVal:
    snes.bus.mem[0x7E0000 + FreezeLockB] = FreezeClearVal.uint8
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF

proc main() =
  # A) poke 00 on freeze seat
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(FreezePath)), snes, c)
    echo fmt"A before 10E5={readU8(snes,FreezeLockA):02X} 10E7={readU8(snes,FreezeLockB):02X}"
    clearSouthFreeze(snes)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let i = PlayerSlot * SlotIndexStride
    var maxGs = giantStepPercent(snes)
    var maxStep = 0
    var lastX = readU16(snes, WorldXBase + i)
    var lastY = readU16(snes, WorldYBase + i)
    for f in 1 .. 500:
      snes.joy1 = 0x0200'u16
      if (f mod 36) < 10: snes.joy1 = 0x0A00'u16
      policy.stepOneFrame(snes, c, img)
      clearSouthFreeze(snes) # hold clear
      let px = readU16(snes, WorldXBase + i)
      let py = readU16(snes, WorldYBase + i)
      let step = abs(int(px)-int(lastX))+abs(int(py)-int(lastY))
      if step > maxStep: maxStep = step
      lastX = px; lastY = py
      let gs = giantStepPercent(snes)
      if gs > maxGs: maxGs = gs
    echo fmt"A poke00 Left end=(0x{lastX:04X},0x{lastY:04X}) maxStep={maxStep} maxGs={maxGs}"
    doAssert maxGs >= 70, "clear $10E5/$10E7 must allow gs70"
    doAssert maxStep <= 8 and maxStep > 0, "must be walk-like steps"

  # B) continuous outdoor frank then clear then giant
  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
    let L = lua53.newstate()
    L.openSandbox()
    policy.setupPolicyApi(L, ctx)
    loadChunk(L, skills(), "sk")
    loadChunk(L, AgentFrankPolicy, "frank")
    var maxFr = 0
    for f in 1 .. 6000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      let fr = frankPercent(snes)
      if fr > maxFr: maxFr = fr
      if maxFr >= 90 and f > 1500: break
    echo fmt"B after frank maxFr={maxFr} 10E5={readU8(snes,FreezeLockA):02X} 10E7={readU8(snes,FreezeLockB):02X}"
    clearSouthFreeze(snes)
    loadChunk(L, AgentGiantStepPolicy, "giant")
    var maxGs = giantStepPercent(snes)
    for f in 1 .. 8000:
      ctx.frameCount = f
      discard policy.runPolicyFrame(L, ctx)
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, c, img)
      snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
      clearSouthFreeze(snes)
      let gs = giantStepPercent(snes)
      if gs > maxGs: maxGs = gs
      if maxGs >= 70 and f > 1000: break
    let i = PlayerSlot * SlotIndexStride
    echo fmt"B continuous after clear maxGs={maxGs} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    doAssert maxGs >= 70, "continuous outdoor+clear must hit gs70"

  echo "OK probe_south_freeze_clear"

when isMainModule:
  main()
