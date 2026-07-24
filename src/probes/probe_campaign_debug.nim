## Long-campaign debug dump: fixture grades, scene head, spine, battle fields.
## Usage: nim r -d:release src/probes/probe_campaign_debug.nim [state]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents, scene, llm_ai]

proc main() =
  ## Print structured progress lines for SCRATCH capture / iteration.
  let rom = "bin/Earthbound (U) [!].smc"
  var statePath = if paramCount() >= 1: paramStr(1) else: "bin/states/llm/pokey_done.state"
  if not fileExists(rom):
    echo "SKIP: no rom"; quit(0)
  if not fileExists(statePath):
    statePath = "bin/states/llm/onett_start.state"
  if not fileExists(statePath):
    echo "SKIP: no state"; quit(0)

  let snes = newSnesBus(policy.readRomFile(rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for i in 0 .. 5:
    policy.stepOneFrame(snes, cpu, img)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 6, joy1: 0, targetFps: 0)
  let summary = buildStateSummary(ctx)
  let sc = sceneJson(snes)
  let spine = checkpointSpineLine(snes)
  echo "DEBUG_FIXTURE: ", statePath
  echo "DEBUG_METRICS: tg=", touchGrassPercent(snes),
    " pokey=", pokeyPercent(snes),
    " knock=", pokeyKnockPercent(snes),
    " room=", currentRoomLabel(snes)
  echo "DEBUG_SPINE: ", spine
  echo "DEBUG_SCENE_HEAD: ", sc[0 ..< min(200, sc.len)]
  echo "DEBUG_SUMMARY_HAS_SCENE: ", ("nearby_entities" in summary or "SCENE" in summary)
  echo "DEBUG_SUMMARY_HAS_BATTLE_FIELDS: ",
    ("battle_flag_$4DBA" in summary and "battle_command_menu" in summary and
     "in_battle:" in summary)
  echo "DEBUG_SUMMARY_HAS_ON_SCREEN: ", ("on_screen_text" in sc)
  # Print a few summary lines for battle block
  for line in summary.splitLines():
    if line.startsWith("in_battle") or line.startsWith("battle_") or
        line.startsWith("party_hp") or line.startsWith(">>> CURRENT"):
      echo "DEBUG_LINE: ", line

when isMainModule:
  main()
