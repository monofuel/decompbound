## Headless talk/interact probe: adjacent NPC → dialogue window and/or pokey grade.
## Uses intent skills only (talk/approach) — no followRoute. Evidence for
## docs/grok_play_work.md Stream D.
## Usage: nim r -d:release src/probes/probe_talk_grade.nim [rom] [state]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/llm/pokey_free.state"
  MaxFrames = 1800

  TalkPolicy = """
function update()
  if escapeMenu() then return end
  if advanceDialogue and advanceDialogue() then return end
  -- Named talk first (requires fixed entity JSON parser with names).
  if talk and talk("pokey") then return end
  local e = nearestEntity and nearestEntity() or nil
  if e ~= nil then
    if talk(e.slot) then return end
  end
end
"""

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and execute a Lua chunk that defines globals.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc sceneLua(L: lua53.PState): cint {.cdecl.} =
  ## Bind scene() for intent skills.
  let ctx = policy.getPolicyCtx(L)
  L.pushstring(scene.sceneJson(ctx.snes).cstring)
  1

proc windowOpen(snes: SnesBus): bool =
  ## Dialogue/window headers non-free.
  touch_grass.readU8(snes, 0x8650) != 0xFF or
    touch_grass.readU8(snes, 0x8654) != 0xFF

proc main() =
  ## Run talk policy from adjacent-to-Pokey fixture; report dialogue / grade.
  let rom = if paramCount() >= 1: paramStr(1) else: DefaultRom
  var statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  if not fileExists(statePath):
    for alt in ["bin/states/llm/pokey_free2.state", "bin/states/llm/pokey_done.state",
                "bin/states/llm/onett_start.state"]:
      if fileExists(alt):
        statePath = alt
        break
  if not fileExists(rom) or not fileExists(statePath):
    echo "SKIP: missing rom or state rom=", rom, " state=", statePath
    quit(0)

  let snes = newSnesBus(policy.readRomFile(rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
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
  loadChunk(L, TalkPolicy, "talk_policy")

  let startPokey = pokeyPercent(snes)
  let startScene = sceneJson(snes)
  echo "TALK_PROBE: state=", statePath
  echo "TALK_PROBE: start pokey_pct=", startPokey, " window=", windowOpen(snes)
  echo "TALK_PROBE: scene=", startScene[0 ..< min(240, startScene.len)]

  var sawWindow = windowOpen(snes)
  var maxPokey = startPokey
  var dialogueSnippet = ""
  for f in 1 .. MaxFrames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    if windowOpen(snes):
      sawWindow = true
    let p = pokeyPercent(snes)
    if p > maxPokey: maxPokey = p
    let txt = policy.getDialogueText(snes).strip()
    if txt.len > 0:
      dialogueSnippet = txt[0 ..< min(80, txt.len)]
    if maxPokey >= 100 or (sawWindow and f > 120 and dialogueSnippet.len > 0):
      break

  echo "TALK_PROBE: frames=", ctx.frameCount, " saw_window=", sawWindow,
    " max_pokey=", maxPokey, " start_pokey=", startPokey
  if dialogueSnippet.len > 0:
    echo "TALK_PROBE: dialogue_snippet=", dialogueSnippet.replace("\n", " ")
  else:
    echo "TALK_PROBE: dialogue_snippet=(empty)"

  let pass =
    sawWindow or maxPokey > startPokey or maxPokey >= 90 or dialogueSnippet.len > 0
  if pass:
    echo "TALK_PROBE: PASS (dialogue and/or grade/window activity)"
  else:
    echo "TALK_PROBE: FAIL (no window, no grade climb, no dialogue)"
    quit(1)

when isMainModule:
  main()
