## Gate tool for battle-capable fixture.
## Usage: nim r src/tools/battle_fixture_check.nim -- --state bin/states/battle_fixture.state
## or --slot 1 (loads bin/states/slot1.state)
## Exits 0 if ok, 1 with diagnostics if not.
## Must be run before battle evidence capture per strategy.

import
  std/[os, strformat, strutils, parseopt],
  ../decompbound/[snesbus, cpu, save_state],
  ./touch_grass

proc loadAndCheck(path: string): (bool, string) =
  if not fileExists(path):
    return (false, "file not found: " & path)
  let data = cast[seq[byte]](readFile(path))
  var snes = newSnesBus(@[])
  var c: Cpu
  try:
    deserializeState(data, snes, c)
  except CatchableError as e:
    return (false, "deserialize failed: " & e.msg)
  let (ok, diag) = touch_grass.battleFixtureOk(snes)
  if ok:
    return (true, "OK")
  else:
    let tg = touch_grass.touchGrassPercent(snes)
    let flag = touch_grass.readU8(snes, 0x4DBA)
    let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
    let px = touch_grass.readU16(snes, touch_grass.WorldXBase + pidx)
    let py = touch_grass.readU16(snes, touch_grass.WorldYBase + pidx)
    return (false, diag & " (tg=" & $tg & " flag=" & $flag & " pos=0x" & $px & ",0x" & $py & ")")

when isMainModule:
  var statePath = ""
  var slot = -1
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      if key == "state" or key == "s":
        statePath = val
      elif key == "slot":
        slot = parseInt(val)
      elif key == "help" or key == "h":
        echo "battle_fixture_check --state PATH | --slot N"
        quit(0)
    else: discard

  if statePath.len == 0 and slot >= 0:
    statePath = fmt"bin/states/slot{slot}.state"
  elif statePath.len == 0:
    statePath = "bin/states/battle_fixture.state"

  let (ok, diag) = loadAndCheck(statePath)
  echo "battle_fixture_check ", statePath, ": ", (if ok: "PASS" else: "FAIL"), " ", diag
  if not ok:
    quit(1)
  quit(0)
