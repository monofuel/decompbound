## Minimal smoke test for embedded Lua 5.3.
## Creates a state, opens the standard libs, and executes a tiny script that
## exercises print and basic arithmetic/string concat. The script must output
## exactly "hello from lua 4" (plus newline) for success.
## Usage: make lua-test   or   nim r src/tools/lua_test.nim

import
  std/strformat,
  ../decompbound/lua53

proc main() =
  ## Set up a fresh Lua state and run the test chunk.
  let L = lua53.newstate()
  if L == nil:
    echo "ERROR: luaL_newstate returned nil"
    quit(1)

  lua53.openlibs(L)

  const script = """print("hello from lua " .. tostring(2+2))"""
  let loadStatus = L.loadbuffer(script.cstring, script.len.cint, "test".cstring)
  if loadStatus != lua53.OK:
    echo fmt"ERROR: loadbuffer failed with status {loadStatus}"
    quit(1)

  let pcallStatus = L.pcall(0, lua53.MULTRET, 0)
  if pcallStatus != lua53.OK:
    echo fmt"ERROR: pcall failed with status {pcallStatus}"
    quit(1)

  echo "Lua demo completed (script output should appear above)."

when isMainModule:
  main()
