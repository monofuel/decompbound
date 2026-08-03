## Scene JSON + checkpoint spine from real ROM + LLM fixtures (shipped path).
import
  std/[os, strutils, json],
  ../src/decompbound/[cpu, snesbus, save_state, policy],
  ../src/tools/[scene, story_percents, touch_grass]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  StateDir = "bin/states/llm"

proc loadState(path: string, snes: SnesBus, c: var Cpu) =
  ## Deserialize a fixture state file into the live bus.
  doAssert fileExists(path), "missing fixture: " & path
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)

proc main() =
  ## Exercise sceneJson + checkpointSpineLine on real fixtures.
  doAssert fileExists(DefaultRom), "need user ROM at " & DefaultRom
  let snes = newSnesBus(policy.readRomFile(DefaultRom))
  var c = snes.resetCpu()

  let candidates = [
    StateDir / "pokey_free.state",
    StateDir / "onett_start.state",
    StateDir / "home_door.state",
    StateDir / "bedroom.state",
  ]
  var used = ""
  for p in candidates:
    if fileExists(p):
      used = p
      break
  doAssert used.len > 0, "no llm fixture under " & StateDir

  loadState(used, snes, c)
  let js = sceneJson(snes)
  doAssert "nearby_entities" in js, "scene missing nearby_entities: " & js[0 ..< min(200, js.len)]
  doAssert "on_screen_text" in js
  doAssert "player" in js
  doAssert "room" in js
  # Valid JSON structure
  let node = parseJson(js)
  doAssert node.hasKey("nearby_entities")
  doAssert node.hasKey("on_screen_text")
  doAssert node.hasKey("player")

  let spine = checkpointSpineLine(snes)
  doAssert spine.startsWith("checkpoint_spine:")
  for id in ["tg=", "pokey=", "frank=", "peaceful_rest=", "lilliput_steps=",
      "monotoli=", "summers=", "deep_darkness=", "stonehenge=", "giygas="]:
    doAssert id in spine, "spine missing " & id & ": " & spine
  # Full catalog ids present as stub slots (checkpoints.md backbone)
  doAssert CheckpointSpine.len >= 16

  let tg = touchGrassPercent(snes)
  let pokey = pokeyPercent(snes)
  echo "OK test_scene_and_checkpoints fixture=", used
  echo "  scene_chars=", js.len, " entities=", node["nearby_entities"].len
  echo "  tg=", tg, " pokey=", pokey
  echo "  ", spine
  echo "  scene_head=", js[0 ..< min(180, js.len)]

when isMainModule:
  main()
