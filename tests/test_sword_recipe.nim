## Referee for the Sword of Kings recipe tool against local slot230.
##
## 1) State-class detection unit: synthetic window headers on a fresh bus
##    (no ROM state) → branch choice for parked / B-status / command menu.
## 2) slot230 end-to-end: exit 0 and the known N=32 drop hit (solo Starman
##    Super, AA10=$23). SKIP cleanly with exit 0 when slot230 is absent —
##    it is local-only and never committed.

import
  std/[os, osproc, strformat, strutils],
  decompbound/snesbus,
  tools/sword_recipe

const
  StatePath = "bin/states/slot230.state"
  ToolPath = "src/tools/sword_recipe.nim"
  RomPath = "bin/Earthbound (U) [!].smc"

proc testStateClassDetection() =
  ## Synthetic window headers → detectStateClass branch choice.
  ## Fresh bus only; no ROM image or save-state required.
  let snes = newSnesBus(@[])

  setWindowHeaders(snes, WindowHeaders(
    h8650: 0xFF, h8654: 0xFF, h8658: 0xFF, h8958: 0xFF))
  doAssert detectStateClass(snes) == scParkedOverworld,
    "all-FF headers must be parked overworld"

  setWindowHeaders(snes, WindowHeaders(
    h8650: 0xFF, h8654: 0x0A, h8658: 0x0A, h8958: 0x0A))
  doAssert detectStateClass(snes) == scBStatusOpen,
    "$8654=0A must be B-status spinner class"

  setWindowHeaders(snes, WindowHeaders(
    h8650: 0x01, h8654: 0xFF, h8658: 0x01, h8958: 0xFF))
  doAssert detectStateClass(snes) == scCommandMenu,
    "$8650=01 must be command menu class"

  # Spinner wins over command-menu bit if both present.
  setWindowHeaders(snes, WindowHeaders(
    h8650: 0x01, h8654: 0x0A, h8658: 0x0A, h8958: 0x0A))
  doAssert detectStateClass(snes) == scBStatusOpen,
    "B-status ($8654=0A) takes priority over $8650=01"

  echo "[test_sword_recipe] state-class detection OK"

proc testSlot230Recipe() =
  ## Run the recipe tool on slot230 when present; assert N=32 hit.
  if not fileExists(StatePath):
    echo "[test_sword_recipe] SKIP e2e (slot230.state absent — local-only fixture)"
    return
  if not fileExists(RomPath):
    echo "[test_sword_recipe] SKIP e2e (ROM absent)"
    return
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
    "N=  32:" in output or
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

  let hasClass =
    "state class:" in output
  if not hasClass:
    echo "[test_sword_recipe] FAIL: expected state-class line in tool output"
    quit(1)

  echo "[test_sword_recipe] OK e2e (exit 0, N=32 present)"

proc main() =
  ## State-class unit + optional slot230 gold pin.
  testStateClassDetection()
  testSlot230Recipe()
  echo "[test_sword_recipe] OK"

when isMainModule:
  main()
