## Referee for the Sword of Kings recipe tool against local slot230.
##
## Expects exit 0 and the known N=32 drop hit (solo Starman Super, AA10=$23).
## SKIP cleanly with exit 0 when slot230 is absent — it is local-only and
## never committed.

import
  std/[os, osproc, strformat, strutils]

const
  StatePath = "bin/states/slot230.state"
  ToolPath = "src/tools/sword_recipe.nim"
  RomPath = "bin/Earthbound (U) [!].smc"

proc main() =
  ## Run the recipe tool on slot230 when present; assert N=32 hit.
  if not fileExists(StatePath):
    echo "[test_sword_recipe] SKIP (slot230.state absent — local-only fixture)"
    quit(0)
  if not fileExists(RomPath):
    echo "[test_sword_recipe] SKIP (ROM absent)"
    quit(0)
  if not fileExists(ToolPath):
    echo &"[test_sword_recipe] FAIL: missing {ToolPath}"
    quit(1)

  let cmd = &"nim r --hints:off {ToolPath} {StatePath} --dir=left"
  echo &"[test_sword_recipe] running: {cmd}"
  let (output, exitCode) = execCmdEx(cmd)
  echo output
  if exitCode != 0:
    echo &"[test_sword_recipe] FAIL: tool exit {exitCode} (want 0)"
    quit(1)

  let hasN32 =
    "dwell frames (B-status window):      32" in output or
    "N= 32:" in output or
    "only hit in 0..127 is N=32" in output
  if not hasN32:
    echo "[test_sword_recipe] FAIL: expected known N=32 hit for slot230"
    quit(1)

  let hasSword =
    "Sword of kings" in output or
    "AA10=0023" in output
  if not hasSword:
    echo "[test_sword_recipe] FAIL: expected Sword of kings / AA10=0023"
    quit(1)

  echo "[test_sword_recipe] OK (exit 0, N=32 present)"

when isMainModule:
  main()
