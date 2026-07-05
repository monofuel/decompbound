## Lua 5.3 minimal FFI binding using the static liblua.a embed technique.
## This is a thin hand-rolled binding modeled on the ~53 line noulith pattern.
## It is sufficient to create a state, load a buffer, and pcall it. No callbacks
## or value marshaling yet; that is milestone 2.

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

type
  # Type of numbers in Lua (for future marshaling).
  Number* = float
  Integer* = cint

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

{.pop.}
