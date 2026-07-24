## Diff free post_knock outdoor vs after AgentBuzz; try mobility restores.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
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

proc snap9800(snes: SnesBus): seq[uint8] =
  result = newSeq[uint8](0x200)
  for i in 0 ..< 0x200:
    result[i] = snes.bus.mem[0x7E9800 + i]

proc dumpKey(snes: SnesBus, label: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"{label}: pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) " &
    fmt"w0={readU8(snes,0x8650):02X} w1={readU8(snes,0x8654):02X} " &
    fmt"9875={readU8(snes,0x9875):02X} 9876={readU8(snes,0x9876):02X} 9877={readU8(snes,0x9877):02X} " &
    fmt"9878={readU8(snes,0x9878):02X} 987A={readU8(snes,0x987A):02X} " &
    fmt"9885={readU8(snes,0x9885):02X} 9887={readU8(snes,0x9887):02X} 99F2={readU8(snes,0x99F2):02X}"

proc tryMove(snes: SnesBus, c: var Cpu, img: Image, label: string) =
  let i = PlayerSlot * SlotIndexStride
  let px0 = int(readU16(snes, WorldXBase + i))
  let py0 = int(readU16(snes, WorldYBase + i))
  for _ in 1 .. 150:
    snes.joy1 = 0x0100
    policy.stepOneFrame(snes, c, img)
  let px1 = int(readU16(snes, WorldXBase + i))
  let py1 = int(readU16(snes, WorldYBase + i))
  echo fmt"{label}: dx={px1-px0} dy={py1-py0} pos=(0x{px1:04X},0x{py1:04X})"

proc main() =
  doAssert fileExists(OutdoorPk)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  let freeSnap = snap9800(snes)
  dumpKey(snes, "FREE")
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  tryMove(snes, c, img, "FREE Right")

  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua)
  L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentBuzzBuzzPolicy, "buzz")
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
  dumpKey(snes, "POST_BUZZ")
  let buzzSnap = snap9800(snes)
  var diffs = 0
  for off in 0 ..< 0x200:
    if freeSnap[off] != buzzSnap[off]:
      if diffs < 50:
        echo fmt"  $98{off:02X}: free={freeSnap[off]:02X} buzz={buzzSnap[off]:02X}"
      diffs += 1
  echo "flag band diffs=", diffs

  tryMove(snes, c, img, "raw Right")
  for f in 1 .. 300:
    snes.joy1 = if (f mod 4) < 2: 0x0080'u16 else: 0x8000'u16
    policy.stepOneFrame(snes, c, img)
  dumpKey(snes, "AFTER_DRAIN")
  tryMove(snes, c, img, "drain Right")

  # bit0 clear 9877
  let l77 = uint8(readU8(snes, 0x9877))
  snes.bus.mem[0x7E0000 + 0x9877] = l77 and 0xFE'u8
  tryMove(snes, c, img, "9877bit0 Right")

  # restore free 9875-987F
  for off in 0x75 .. 0x7F:
    snes.bus.mem[0x7E9800 + off] = freeSnap[off]
  tryMove(snes, c, img, "restore 9875-7F Right")

  # clear windows
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  tryMove(snes, c, img, "force win FF Right")

  # full flag restore
  for off in 0 ..< 0x200:
    snes.bus.mem[0x7E9800 + off] = freeSnap[off]
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  tryMove(snes, c, img, "full 98xx free + winFF Right")

  # reload outdoor at door-ish and AgentFrank without buzz
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, c)
  loadChunk(L, skills, "sk2")
  loadChunk(L, AgentFrankPolicy, "frank")
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 10000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
    if f mod 2500 == 0:
      echo fmt"FRANK_ONLY f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) fr={fr}/{maxFr} gs={gs}/{maxGs}"
  echo fmt"FRANK_ONLY peaks fr={maxFr} gs={maxGs}"
  echo "OK probe_post_buzz_lock"

when isMainModule:
  main()
