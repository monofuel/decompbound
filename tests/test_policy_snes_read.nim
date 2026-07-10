## Referee test for the Lua sandbox full-bus read surface (policy.nim):
## snes.read / snes.readRange must resolve WRAM (+ low-RAM mirrors) and the
## flat ROM image, refuse the MMIO port window (no side effects, always 0),
## clamp readRange lengths, and leave mem.read behavior untouched.
## Fully synthetic (no user ROM required): bytes are poked into bus.mem.

import
  pixie,
  ../src/decompbound/[lua53, policy, ppu, snesbus]

const
  LuaChecks = """
assert(snes.read(0x7E1234) == 0xAB, "WRAM direct")
assert(snes.read(0x001234) == 0xAB, "low-RAM mirror bank 00")
assert(snes.read(0x801234) == 0xAB, "low-RAM mirror bank 80")
assert(snes.read(0xC01234) == 0x77, "ROM flat image")
assert(snes.read(0x002100) == 0, "PPU port refused")
assert(snes.read(0x004210) == 0, "CPU port refused")
local r = snes.readRange(0x7EE000, 8)
assert(#r == 8, "readRange length")
for i = 1, 8 do
  assert(r[i] == 0x10 + i, "readRange content @" .. i)
end
assert(#snes.readRange(0x7E0000, 9000) == 8192, "readRange clamp high")
assert(#snes.readRange(0x7E0000, -5) == 0, "readRange clamp negative")
assert(mem.read(0x1234) == 0xAB, "mem.read unchanged")
"""

proc main() =
  ## Build a synthetic bus, poke known bytes, assert the Lua view of them.
  let rom = newSeq[uint8](0x8000)
  let snes = newSnesBus(rom)
  snes.bus.mem[0x7E1234] = 0xAB
  snes.bus.mem[0xC01234] = 0x77
  # Garbage in the port window that snes.read must refuse to surface.
  snes.bus.mem[0x002100] = 0x55
  snes.bus.mem[0x004210] = 0x55
  for i in 0 ..< 8:
    snes.bus.mem[0x7EE000 + i] = uint8(0x11 + i)

  let L = lua53.newstate()
  if L == nil:
    echo "[test_policy_snes_read] FAIL: luaL_newstate returned nil"
    quit(1)
  lua53.openlibs(L)
  let ctx = PolicyContext(snes: snes, frameImage: newImage(ppu.ScreenWidth, ppu.ScreenHeight))
  setupPolicyApi(L, ctx)

  if L.loadbuffer(LuaChecks.cstring, LuaChecks.len.cint, "snes_read_checks".cstring) != lua53.OK:
    echo "[test_policy_snes_read] FAIL: load: ", L.toString(-1)
    quit(1)
  if L.pcall(0, 0, 0) != lua53.OK:
    echo "[test_policy_snes_read] FAIL: ", L.toString(-1)
    quit(1)

  echo "[test_policy_snes_read] ok: WRAM/mirror/ROM reads + MMIO refusal + range clamps"

when isMainModule:
  main()
