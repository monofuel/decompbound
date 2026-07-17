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
    DoorEnterSkillLua & "\n\n" & NavSkillLua & "\n\n" & FollowTrailSkillLua &
    "\n\n" & NamedRoutesLua & "\n\n" & IntentNavSkillLua
  writeFile("bin/states/llm_skills.lua", seed)
  echo "wrote bin/states/llm_skills.lua len=", seed.len
  if "8650" notin seed or "open-window" notin seed:
    raise newException(ValueError, "skills seed missing window gate")
  if "dialogue-ish text" in seed:
    raise newException(ValueError, "skills seed still has old advanceDialogue string")
  if "doorEnter" notin seed:
    raise newException(ValueError, "skills seed missing doorEnter")
  if "hillClimbNorth" in seed:
    raise newException(ValueError,
      "skills seed still has hillClimbNorth (removed 2026-07-09; navTo replaces it)")
  if "navTo" notin seed:
    raise newException(ValueError, "skills seed missing navTo")
  if "followTrail" notin seed:
    raise newException(ValueError, "skills seed missing followTrail")
  if "followRoute" notin seed or "onett_to_crater" notin seed:
    raise newException(ValueError, "skills seed missing followRoute / onett_to_crater")
  if "nearestEntity" notin seed or "function approach" notin seed or
      "function talk" notin seed or "function goToward" notin seed:
    raise newException(ValueError, "skills seed missing intent-nav verbs")

when isMainModule:
  main()
