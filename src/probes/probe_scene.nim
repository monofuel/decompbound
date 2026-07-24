## Exercise the structured scene JSON on real states — verify the bot could
## perceive "who is near me and in which direction" without any coordinates.
import
  ../decompbound/[cpu, snesbus, save_state, policy],
  ./scene

let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
var c = snes.resetCpu()

for st in ["pokey_free.state", "home_door.state",
           "home_downstairs_night.state", "onett_start.state"]:
  let path = "bin/states/llm/" & st
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)
  echo "\n#### ", st, " ####"
  echo sceneJson(snes)
