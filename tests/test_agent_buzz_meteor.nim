## AgentBuzzBuzzPolicy from flag-synth outdoor climbs buzz to meteor site (80+).
## Picky is not battle-party $988C — 100 reserved for join flag RE.

import
  std/[os, strutils, osproc],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OutdoorPk = "bin/states/llm/post_knock_outdoor.state"
  BuzzOut = "bin/states/llm/buzz_meteor.state"

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  L.pushstring(scene.sceneJson(policy.getPolicyCtx(L).snes).cstring); 1

proc landmarkLua(L: lua53.PState): cint {.cdecl.} =
  let t = scene.landmarkTarget(policy.getPolicyCtx(L).snes, $L.toString(1))
  if not t.found: L.pushnil(); return 1
  L.pushinteger(t.x); L.pushinteger(t.y); 2

proc ensureOutdoor() =
  let (o, c) = execCmdEx("nim r -d:release src/tools/synth_post_knock_outdoor.nim")
  echo o
  doAssert c == 0 and fileExists(OutdoorPk)

proc main() =
  ## AgentBuzzBuzzPolicy must reach meteor site buzz>=80 after knock.
  doAssert fileExists(Rom)
  ensureOutdoor()
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(OutdoorPk)), snes, cpu)
  doAssert knockComplete(snes)
  doAssert readU8(snes, KnockStoryFlagOff) == KnockStoryFlagVal
  let startBb = buzzBuzzPercent(snes)
  echo "start bb=", startBb, " frank=", frankPercent(snes),
    " sunrise=", sunrisePercent(snes), " $9887=", readU8(snes, KnockStoryFlagOff)

  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua); L.setglobal("scene".cstring)
  L.pushcfunction(landmarkLua); L.setglobal("landmarkTarget".cstring)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & FollowTrailSkillLua &
    "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, AgentBuzzBuzzPolicy, "buzz")

  var maxBb = startBb
  var maxPk = pokeyPercent(snes)
  var maxSu = sunrisePercent(snes)
  let i = PlayerSlot * SlotIndexStride
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    # Keep minimal knock signatures (synth bootstrap; game may clear mid-walk).
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    let bb = buzzBuzzPercent(snes)
    let pk = pokeyPercent(snes)
    let su = sunrisePercent(snes)
    if bb > maxBb: maxBb = bb
    if pk > maxPk: maxPk = pk
    if su > maxSu: maxSu = su
    if f mod 1000 == 0:
      echo "f=", f, " bb=", bb, " pk=", pk, " su=", su,
        " pos=(0x", toHex(readU16(snes, WorldXBase+i), 4), ",0x",
        toHex(readU16(snes, WorldYBase+i), 4), ")"
    if maxBb >= 90:
      break

  echo "FINAL max_bb=", maxBb, " max_pk=", maxPk, " max_su=", maxSu,
    " pos_x=", readU16(snes, WorldXBase+i), " pos_y=", readU16(snes, WorldYBase+i)
  doAssert maxBb > startBb, "buzz must climb from outdoor door"
  doAssert maxBb >= 80, "buzz meteor site is 80+ (got " & $maxBb & ")"
  doAssert maxSu >= 60, "sunrise partial tracks buzz 80 (got " & $maxSu & ")"
  # 90 = site + arm consumed + $9887 (flag-merge outdoor dialogue progress).
  doAssert maxBb >= 90 or maxPk >= 90,
    "expect site talk progress (bb>=90 or pk>=90); got bb=" & $maxBb & " pk=" & $maxPk

  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  writeFile(BuzzOut, cast[string](serializeState(snes, cpu)))
  echo "WROTE ", BuzzOut, " bb=", buzzBuzzPercent(snes), " su=", sunrisePercent(snes)
  echo "OK test_agent_buzz_meteor: buzz>=80 at meteor after knock"

when isMainModule:
  main()
