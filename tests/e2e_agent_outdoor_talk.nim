## AgentOutdoorPolicy product path: from pokey_free, talk must exclusive-run
## and advance pokey_pct (not stall at 80 while explore pads fight talk).
## Drives the shipped seed string + IntentNavSkillLua talk() from touch_grass.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../src/tools/[touch_grass, story_percents, scene, llm_mock_policies]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/pokey_free.state"
  MaxFrames = 600

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and exec a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills (same as llm_ai).
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  1

proc main() =
  ## Run shipped AgentOutdoorPolicy from pokey_free; require pokey grade climb.
  doAssert fileExists(DefaultRom), "need ROM at " & DefaultRom
  doAssert fileExists(DefaultState), "need fixture " & DefaultState

  let snes = newSnesBus(policy.readRomFile(DefaultRom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(DefaultState)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)

  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  L.pushcfunction(sceneLua)
  L.setglobal("scene".cstring)

  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & NavSkillLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "skills")
  # Product seed — not a hand-written talk-only policy.
  loadChunk(L, AgentOutdoorPolicy, "agent_outdoor")

  let startPokey = pokeyPercent(snes)
  doAssert startPokey >= 70,
    "fixture should be near meteor site, got pokey=" & $startPokey

  var maxPokey = startPokey
  var sawTalkBusy = false
  for f in 1 .. MaxFrames:
    ctx.frameCount = f
    # Call talk via policy update (AgentOutdoorPolicy body).
    discard policy.runPolicyFrame(L, ctx)
    # Detect exclusive talk: joy1 has A or face d-pad without pure random explore
    # (A bit is 0x0080 on SNES joypad low byte in our harness — use non-zero joy
    # while near Pokey as activity). Progress metric is the load-bearing assert.
    if ctx.joy1 != 0:
      sawTalkBusy = true
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let p = pokeyPercent(snes)
    if p > maxPokey:
      maxPokey = p
    if maxPokey >= 100:
      break

  echo "test_agent_outdoor_talk: start=", startPokey, " max=", maxPokey,
    " frames=", ctx.frameCount, " joy_activity=", sawTalkBusy
  doAssert maxPokey > startPokey or maxPokey >= 90,
    "AgentOutdoorPolicy must advance pokey grade (start=" & $startPokey &
    " max=" & $maxPokey & ") — talk must exclusive-run while busy"
  doAssert maxPokey >= 90,
    "expected adjacency/talk tier >=90, got " & $maxPokey
  echo "OK test_agent_outdoor_talk: AgentOutdoorPolicy advanced pokey ",
    startPokey, "->", maxPokey

when isMainModule:
  main()
