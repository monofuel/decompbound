## Lua 5.3 minimal FFI binding using the static liblua.a embed technique.
## This is a thin hand-rolled binding modeled on the ~53 line noulith pattern.
## Milestone 1: newstate/openlibs/loadbuffer/pcall.
## Milestone 2a (this): register Nim callbacks as Lua globals (pushcclosure+setglobal),
## value marshaling both directions (push*/to*), and debug hook (sethook + MASKCOUNT)
## for interrupting runaway scripts via lua_error unwind from within hook.

when defined(posix) or defined(unix) or defined(linux) or defined(macosx):
  {.passL: "-lm".}
{.passL: "vendor/lua/liblua.a".}

type
  PState* = pointer
  CFunction* = proc (state: PState): cint {.cdecl.}

const
  # Lua status codes and specials (from lua.h / lauxlib.h).
  OK* = 0
  ERRRUN* = 2
  ERRSYNTAX* = 3
  ERRMEM* = 4
  ERRGCMM* = 5
  ERRERR* = 6
  MULTRET* = -1

  # Basic types (lua_type results). Used for marshaling checks.
  TNIL* = 0
  TBOOLEAN* = 1
  TLIGHTUSERDATA* = 2
  TNUMBER* = 3
  TSTRING* = 4
  TTABLE* = 5
  TFUNCTION* = 6
  TUSERDATA* = 7
  TTHREAD* = 8

  # Debug hook mask for instruction count. In Lua 5.3:
  # LUA_HOOKCOUNT = 3, LUA_MASKCOUNT = (1 << 3) = 8.
  # (Task note mentioned =2; that may be for HOOKLINE in some versions/docs.
  # Actual value from vendor/lua/lua.h and ldebug.c is 8.)
  MASKCOUNT* = 1 shl 3

  # Registry index for storing lightuserdata ctx and other per-state values.
  # This build of liblua.a pulls in ltests.h which forces LUAI_MAXSTACK=50000.
  RegistryIndex* = -50000 - 1000

  # Button bitmasks are not here; the policy runner owns the mapping and joy1.

type
  # Type of numbers in Lua (for marshaling). Lua 5.3 defaults to 64-bit lua_Integer
  # (long long) on 64-bit platforms unless LUA_32BITS or LUA_C89_NUMBERS defined.
  # See vendor/lua/luaconf.h. Using clonglong here to match the static lib build.
  Number* = float
  Integer* = clonglong

  # Hook type for lua_sethook. We use pointer for lua_Debug to avoid needing full
  # layout (count hooks typically ignore the ar details).
  Hook* = proc (L: PState, ar: pointer) {.cdecl.}

{.pragma: ilua, importc: "lua_$1".} # lua.h
{.pragma: iluaL, importc: "luaL_$1".} # lauxlib.h

{.push callConv: cdecl.}

proc newstate*(): PState {.iluaL.}
  ## Create a new Lua state using the default allocator.

proc openlibs*(state: PState) {.importc: "luaL_openlibs".}
  ## Open the standard libraries in the given state.

proc loadbufferx*(state: PState, buff: cstring, size: cint, name: cstring, mode: cstring): cint {.iluaL.}
  ## Load a buffer as a Lua chunk. Returns status code.

proc loadbuffer*(state: PState, buff: cstring, size: cint, name: cstring): cint {.inline.} =
  ## Convenience wrapper around loadbufferx with automatic mode detection.
  state.loadbufferx(buff, size, name, nil)

proc pcallk*(L: PState; nargs: cint; nresults: cint; errfunc: cint;
                 ctx: cint; k: CFunction): cint {.ilua.}
  ## Protected call with continuation (internal).

proc pcall*(L: PState; nargs, nresults, errFunc: cint): cint {.inline.} =
  ## Protected call. Returns LUA_OK on success.
  L.pcallk(nargs, nresults, errFunc, 0, nil)

  # --- Milestone 2a FFI additions: callbacks, marshal, debug hook ---

proc pushcclosure*(L: PState, fn: CFunction, n: cint) {.ilua.}
  ## Push C function as closure with n upvalues.

proc setglobal*(L: PState, name: cstring) {.ilua.}
  ## Pop value and set as global 'name'.

proc pushinteger*(L: PState, n: Integer) {.ilua.}
  ## Push integer onto Lua stack.

proc pushstring*(L: PState, s: cstring) {.ilua.}
  ## Push zero-terminated string.

proc pushboolean*(L: PState, b: cint) {.ilua.}
  ## Push boolean (0 false, non-zero true).

proc pushnil*(L: PState) {.ilua.}
  ## Push nil.

proc gettop*(L: PState): cint {.ilua.}
  ## Return current stack top index (num elements).

proc tointegerx*(L: PState, idx: cint, isnum: ptr cint): Integer {.ilua.}
  ## Read integer from stack idx (1-based). isnum optional out flag.

proc tolstring*(L: PState, idx: cint, len: ptr csize_t): cstring {.ilua.}
  ## Read string (or convert) at idx. len optional.

proc toboolean*(L: PState, idx: cint): cint {.ilua.}
  ## Read boolean at idx (Lua rules: nil/false = 0 else 1).

proc `type`*(L: PState, idx: cint): cint {.ilua.}
  ## Return type tag at idx (one of TNIL etc). Use backticks as 'type' is keyword.

proc settop*(L: PState, idx: cint) {.ilua.}
  ## Set stack top (use negative to pop relative).

proc error*(L: PState): cint {.ilua.}
  ## Raise Lua error (never returns; longjmps internally). Call after pushing msg.

proc sethook*(L: PState, fn: Hook, mask: cint, count: cint) {.ilua.}
  ## Install debug hook. For count interrupt: mask=MASKCOUNT, count=N.

proc close*(L: PState) {.ilua.}
  ## Close the Lua state and free all associated memory.

  # --- 2b additions: lightuserdata for ctx passing, table construction for namespaced API ---
proc pushlightuserdata*(L: PState, p: pointer) {.ilua.}
  ## Push a light userdata pointer (used to pass Nim ctx into Lua closures via upvalues or registry).

proc touserdata*(L: PState, idx: cint): pointer {.ilua.}
  ## Read a userdata (light or full) pointer from stack idx.

proc createtable*(L: PState, narr: cint, nrec: cint) {.ilua.}
  ## Create a new table with narr array slots and nrec hash slots preallocated.

proc setfield*(L: PState, idx: cint, k: cstring) {.ilua.}
  ## Pop value and set t[k] = value where t is at idx (for building screen/mem/pad tables).

proc getfield*(L: PState, idx: cint, k: cstring) {.ilua.}
  ## Push t[k] onto stack (for retrieving ctx from registry if needed).

proc getglobal*(L: PState, name: cstring) {.ilua.}
  ## Push the global 'name' onto the stack (equivalent to getfield(globals, name)).

{.pop.}

proc pushcfunction*(L: PState, f: CFunction) {.inline.} =
  ## Push a C function as Lua function (0 upvalues). Wrapper for pushcclosure.
  L.pushcclosure(f, 0)

proc register*(L: PState, name: cstring, f: CFunction) {.inline.} =
  ## Register Nim proc (cdecl CFunction) as a Lua global. Uses pushcfunction + setglobal.
  ## This is the core for exposing hostAdd etc to scripts.
  L.pushcfunction(f)
  L.setglobal(name)

proc pop*(L: PState, n: cint = 1) {.inline.} =
  ## Pop n values from stack. Nim-friendly.
  L.settop(-n - 1)

proc toInteger*(L: PState, idx: cint): Integer {.inline.} =
  ## Read integer at idx (ignore isnum flag). Nim-friendly.
  L.tointegerx(idx, nil)

proc toString*(L: PState, idx: cint): string {.inline.} =
  ## Read string at idx as Nim string (or "" if nil). Nim-friendly helper.
  var len: csize_t = 0
  let s = L.tolstring(idx, addr len)
  if s == nil: "" else: $s

proc toBool*(L: PState, idx: cint): bool {.inline.} =
  ## Read as Nim bool. Nim-friendly. (Named toBool to avoid Nim identifier style
  ## collision with the raw toboolean binding.)
  L.toboolean(idx) != 0

proc getType*(L: PState, idx: cint): cint {.inline.} =
  ## Alias to avoid keyword. Nim-friendly.
  L.`type`(idx)

proc upvalueindex*(i: cint): cint {.inline.} =
  ## Return pseudo-index for upvalue i (1-based) when inside a CFunction closure.
  ## Equivalent to LUA_REGISTRYINDEX - i.
  RegistryIndex - i

proc newtable*(L: PState) {.inline.} =
  ## Create empty table (0,0). Nim-friendly.
  L.createtable(0, 0)

proc openSandbox*(L: PState) =
  ## Open a minimal sandboxed set of libs (base + math + string + table) and
  ## explicitly remove dangerous globals (os, io, package, debug, dofile, loadfile,
  ## load, require) so that untrusted Lua policies cannot access the host FS or
  ## network. Print is left for debuggability during development.
  L.openlibs()
  for bad in ["os", "io", "package", "debug"]:
    L.pushnil()
    L.setglobal(bad.cstring)
  for bad in ["dofile", "loadfile", "load", "loadstring", "require"]:
    L.pushnil()
    L.setglobal(bad.cstring)
