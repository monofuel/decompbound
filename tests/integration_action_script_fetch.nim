## Gold-gate the action-script VM fetch loop from asm/actionScriptFetch.asm.

import
  std/unittest,
  decompbound/[adopted, rom_pipeline]

const
  FetchStart = ActionScriptFetchOffset
  FetchLen = 82

suite "action script fetch":
  test "actionScriptFetch() length is the known span":
    check actionScriptFetch().len == FetchLen

  test "actionScriptFetch() matches gold ROM bytes byte-for-byte":
    if not goldBaseromAvailable():
      echo "[test_action_script_fetch] skip gold (no baserom)"
    else:
      let gold = readGoldBaserom()
      let slice = gold[FetchStart ..< FetchStart + FetchLen]
      check actionScriptFetch() == slice

echo "[test_action_script_fetch] ok"
