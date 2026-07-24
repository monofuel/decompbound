## Gold-gate the action-script VM fetch loop: actionScriptFetch() (snesAsm)
## must be byte-identical to the gold ROM at file 0x9506..0x9557 (SNES
## $C09506, 82 bytes: LDX $8A .. RTS).

import
  std/[os, unittest],
  ../src/decompbound/snes_src/action_script_fetch

const
  GoldMasterRom = "bin/Earthbound (U) [!].smc"
  FetchStart = ActionScriptFetchOffset
  FetchLen = ActionScriptFetchLen

suite "action-script fetch loop":
  test "actionScriptFetch() length is the known span":
    check actionScriptFetch().len == FetchLen

  test "actionScriptFetch() matches gold ROM bytes byte-for-byte":
    if not fileExists(GoldMasterRom):
      skip()
    let gold = readFile(GoldMasterRom)
    var slice = newSeq[uint8](FetchLen)
    for i in 0..<FetchLen:
      slice[i] = gold[FetchStart + i].uint8
    check actionScriptFetch() == slice
