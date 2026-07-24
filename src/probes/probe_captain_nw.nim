## From captain/giant approach, NW detour to captain 50+; flag-diff WRAM.
import
  std/[os, strformat, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

const FlagLo = 0x9880
const FlagHi = 0x9C00

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc snap(snes: SnesBus): Table[int, int] =
  result = initTable[int, int]()
  for off in FlagLo ..< FlagHi:
    result[off] = readU8(snes, off)

proc runFrom(path, name, pol: string) =
  if not fileExists(path):
    echo "SKIP ", path
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let base = snap(snes)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  loadChunk(L, EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua, "sk")
  loadChunk(L, pol, name)
  var maxCs = captainStrongPercent(snes)
  var maxFr = frankPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START {name} from={path} cs={maxCs} fr={maxFr} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  for f in 1 .. 8000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let cs = captainStrongPercent(snes)
    let fr = frankPercent(snes)
    if cs > maxCs:
      maxCs = cs
      echo fmt"  NEW cs={maxCs} f={f} fr={fr} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    if fr > maxFr: maxFr = fr
    if maxCs >= 60: break
  echo fmt"FINAL {name} max_cs={maxCs} max_fr={maxFr} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  if maxCs >= 50:
    writeFile("bin/states/llm/captain_west.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE captain_west.state cs=", captainStrongPercent(snes)
  var n = 0
  let cur = snap(snes)
  for off, va in base:
    let vb = cur.getOrDefault(off, va)
    if va != vb:
      if n < 15: echo fmt"  flag ${off:04X}: 0x{va:02X}->0x{vb:02X}"
      n.inc
  echo "  flagdiffs=", n

const NwPol = """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- climb north of the 0x08F0 wall band then west
  if py > 0x0250 then
    pad.press("Up")
    if (frame() % 20) < 6 then pad.press("Left") end
    return
  end
  if px > 0x0820 then
    pad.press("Left")
    if (frame() % 24) < 8 then pad.press("Up") end
    return
  end
  if py < 0x02A0 then
    pad.press("Down")
    if (frame() % 30) < 8 then pad.press("Left") end
    return
  end
  pad.press("Left")
end
"""

const WestPulse = """
function update()
  if escapeMenu() then return end
  pad.press("Left")
  if (frame() % 32) < 10 then pad.press("Up") end
  if (frame() % 32) >= 24 then pad.press("Down") end
end
"""

proc main() =
  let base =
    if fileExists("bin/states/llm/captain_approach.state"):
      "bin/states/llm/captain_approach.state"
    else:
      "bin/states/llm/giant_approach.state"
  runFrom(base, "nw_detour", NwPol)
  runFrom(base, "west_pulse", WestPulse)
  runFrom("bin/states/llm/giant_approach.state", "nw_from_giant", NwPol)

when isMainModule: main()
