## Rewrite bin/states/llm_skills.lua from current touch_grass skill consts.
## Usage: nim r src/tools/regen_llm_skills.nim

import
  std/[os, strutils],
  ./touch_grass

proc main() =
  ## Seed persistent skill library from source-of-truth Lua consts.
  createDir("bin/states")
  let seed = EscapeMenuSkillLua & "\n\n" & WalkToSkillLua & "\n\n" & IntroSkillLua &
    "\n\n" & WinBattleSkillLua & "\n\n" & AdvanceDialogueSkillLua & "\n\n" &
    HillClimbNorthSkillLua & "\n\n" & DoorEnterSkillLua
  writeFile("bin/states/llm_skills.lua", seed)
  echo "wrote bin/states/llm_skills.lua len=", seed.len
  if "8650" notin seed or "window open" notin seed:
    raise newException(ValueError, "skills seed missing window gate")
  if "dialogue-ish text" in seed:
    raise newException(ValueError, "skills seed still has old advanceDialogue string")
  if "doorEnter" notin seed:
    raise newException(ValueError, "skills seed missing doorEnter")
  if "hillClimbNorth" notin seed:
    raise newException(ValueError, "skills seed missing hillClimbNorth")

when isMainModule:
  main()
