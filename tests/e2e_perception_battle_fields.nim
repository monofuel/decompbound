## Perception surface: overworld scene + battle fields always in buildStateSummary.

import
  std/[os, strutils],
  pixie,
  ../src/decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../src/tools/[scene, llm_ai, touch_grass]

const
  Rom = "bin/Earthbound (U) [!].smc"
  OwState = "bin/states/llm/onett_start.state"

proc summaryFor(path: string): string =
  ## Load fixture, step a few frames, return shipped buildStateSummary text.
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  for i in 0 .. 10:
    policy.stepOneFrame(snes, cpu, img)
  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 10, joy1: 0, targetFps: 0)
  buildStateSummary(ctx)

proc main() =
  ## Overworld summary always includes scene + battle field keys.
  doAssert fileExists(Rom)
  doAssert fileExists(OwState)
  let ow = summaryFor(OwState)
  doAssert "SCENE" in ow or "nearby_entities" in ow
  doAssert "in_battle:" in ow
  doAssert "battle_flag_$4DBA:" in ow
  doAssert "battle_command_menu:" in ow
  doAssert "battle_screen_text:" in ow
  doAssert "party_hp_pp:" in ow
  let sc = sceneJson(
    block:
      let snes = newSnesBus(policy.readRomFile(Rom))
      var cpu = snes.resetCpu()
      deserializeState(cast[seq[byte]](readFile(OwState)), snes, cpu)
      snes)
  doAssert "nearby_entities" in sc
  doAssert "on_screen_text" in sc
  doAssert "room" in sc
  echo "OK overworld perception fields present"

  # Battle fixture if available (bin/states/ not only llm/)
  var battlePath = ""
  for p in ["bin/states/llm/battle.state", "bin/states/battle_fixture.state",
            "bin/states/slot1_battle.state", "bin/states/battle_menu_healthy.state"]:
    if fileExists(p):
      battlePath = p
      break
  if battlePath.len == 0:
    echo "SKIP battle fixture: none under bin/states (overworld path still proven)"
  else:
    let b = summaryFor(battlePath)
    doAssert "battle_flag_$4DBA:" in b
    doAssert "in_battle:" in b
    echo "OK battle fixture summary: ", battlePath,
      " in_battle_line present; flag block present"
    if "in_battle: yes" in b:
      echo "  live in_battle=yes on fixture"
    else:
      echo "  note: fixture may not set battle flag; fields still present"

  echo "OK test_perception_battle_fields"

when isMainModule:
  main()
