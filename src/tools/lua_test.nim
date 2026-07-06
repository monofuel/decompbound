## Smoke test for embedded Lua 5.3 (milestone 1 + 2a FFI).
## Milestone 1: basic load/pcall.
## Milestone 2a: 1) register Nim CFunction as Lua global (hostAdd), marshal
## ints both ways, Lua calls it and prints result. 2) sethook(MASKCOUNT) +
## hook that calls lua_error to interrupt infinite loop (no hang).
## Usage: make lua-test   or   nim r src/tools/lua_test.nim

import
  std/strformat,
  ../decompbound/lua53

proc hostAdd(L: lua53.PState): cint {.cdecl.} =
  ## Nim proc registered as Lua global "hostAdd". Reads 2 args via toInteger,
  ## pushes sum via pushinteger, returns 1 result. Proves Lua->Nim call + marshal.
  let a = L.toInteger(1)
  let b = L.toInteger(2)
  L.pushinteger(a + b)
  return 1

proc countHook(L: lua53.PState, ar: pointer) {.cdecl.} =
  ## Debug hook proc. Installed via sethook with MASKCOUNT mask.
  ## Pushes msg and calls error() which longjmps out of the Lua VM (unwinds pcall).
  ## This is how we bound CPU time for untrusted scripts (e.g. LLM policies).
  L.pushstring("interrupted by debug hook after instruction count limit".cstring)
  discard L.error()  # never returns

proc main() =
  ## Run two proofs for the FFI extension.
  # --- 1. Callback + marshal proof: hostAdd(2,3) from Lua must yield 5 printed ---
  let L = lua53.newstate()
  if L == nil:
    echo "ERROR: luaL_newstate returned nil"
    quit(1)

  lua53.openlibs(L)

  # Register the Nim proc BEFORE running script. Uses our pushcfunction+setglobal.
  L.register("hostAdd".cstring, hostAdd)

  const addScript = """print(hostAdd(2, 3))"""
  let loadStatus = L.loadbuffer(addScript.cstring, addScript.len.cint, "addtest".cstring)
  if loadStatus != lua53.OK:
    echo fmt"ERROR: loadbuffer failed with status {loadStatus}"
    quit(1)

  let pcallStatus = L.pcall(0, lua53.MULTRET, 0)
  if pcallStatus != lua53.OK:
    echo fmt"ERROR: pcall for hostAdd failed with status {pcallStatus}: {L.toString(-1)}"
    L.pop(1)
    quit(1)

  echo "hostAdd test passed (expect '5' printed by Lua above)."

  # --- 2. Debug hook interrupt proof: while true must not hang, must ERRRUN ---
  let L2 = lua53.newstate()
  if L2 == nil:
    echo "ERROR: second newstate nil"
    quit(1)

  lua53.openlibs(L2)

  # Install count hook *before* loading/running the chunk.
  # N=1000 instructions is plenty to trigger fast without noticeable delay.
  const InstrCount = 1000.cint
  L2.sethook(countHook, lua53.MASKCOUNT, InstrCount)

  const loopScript = """while true do end"""
  let loadStatus2 = L2.loadbuffer(loopScript.cstring, loopScript.len.cint, "looptest".cstring)
  if loadStatus2 != lua53.OK:
    echo fmt"ERROR: loadbuffer for loop failed with status {loadStatus2}"
    quit(1)

  let pcallStatus2 = L2.pcall(0, lua53.MULTRET, 0)
  if pcallStatus2 != lua53.ERRRUN:
    echo fmt"ERROR: expected ERRRUN from interrupt hook, got {pcallStatus2}"
    if pcallStatus2 != lua53.OK:
      echo "msg: ", L2.toString(-1)
      L2.pop(1)
    quit(1)

  let errMsg = L2.toString(-1)
  L2.pop(1)
  echo fmt"interrupt test passed: got ERRRUN as expected. msg: {errMsg}"

  L.close()
  L2.close()
  echo "Lua FFI milestone 2a demo completed successfully."
  quit(0)

when isMainModule:
  main()
