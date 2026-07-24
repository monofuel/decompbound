## South-road waypoints (onett_to_crater early segment) for frank 60/80.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents]

proc loadChunk(L: lua53.PState, src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc runFrom(label, statePath, pol: string, maxF: int) =
  if not fileExists(statePath):
    echo "SKIP missing ", statePath
    return
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, cpu)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate(); L.openSandbox(); policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua &
    "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & IntentNavSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, pol, label)
  var maxFr = frankPercent(snes)
  let i = PlayerSlot * SlotIndexStride
  echo fmt"START {label} path={statePath} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) frank={maxFr}"
  for f in 1 .. maxF:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    let fr = frankPercent(snes)
    if fr > maxFr:
      maxFr = fr
      echo fmt"  NEW frank={maxFr} f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
    if f mod 1500 == 0:
      echo fmt"  f={f} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) frank={fr} max={maxFr} joy=0x{ctx.joy1:04X}"
    if maxFr >= 80: break
  echo fmt"FINAL {label} max_frank={maxFr} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X})"
  if maxFr >= 60:
    writeFile("bin/states/llm/frank_downtown.state", cast[string](serializeState(snes, cpu)))
    echo "WROTE bin/states/llm/frank_downtown.state frank=", frankPercent(snes)

const SouthRoadPol = """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- Exact early onett_to_crater samples (door south to y~0x026D), then deeper south.
  if py < 0x0169 then walkTo(0x0A4B, 0x0169); return end
  if py < 0x0192 then walkTo(0x0A4A, 0x0192); return end
  if py < 0x01AF then walkTo(0x0A2F, 0x01AF); return end
  if py < 0x01BA then walkTo(0x0A09, 0x01BA); return end
  if py < 0x01D7 then walkTo(0x09EC, 0x01D7); return end
  if py < 0x01FE then walkTo(0x09EA, 0x01FE); return end
  if py < 0x0229 then walkTo(0x09EA, 0x0229); return end
  if py < 0x024E then walkTo(0x09E0, 0x024E); return end
  -- frank 60 band reached; push south for 80
  if py < 0x0280 then walkTo(0x09C0, 0x0290); return end
  if py < 0x0300 then walkTo(0x09A0, 0x0320); return end
  if py < 0x0380 then walkTo(0x0980, 0x0380); return end
  walkTo(0x0960, 0x0400)
end
"""

const FollowRoutePol = """
function update()
  if escapeMenu() then return end
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if py < 0x0250 then
    if followRoute("onett_to_crater") then return end
  end
  if walkTo then walkTo(0x09C0, 0x0320) else pad.press("Down") end
end
"""

const RejoinRoadPol = """
function update()
  if escapeMenu() then return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  -- From mid-town wall west of road: rejoin onett road then south.
  if px < 0x09C0 and py < 0x01D0 then walkTo(0x09EC, 0x01D7); return end
  if py < 0x01FE then walkTo(0x09EA, 0x01FE); return end
  if py < 0x0229 then walkTo(0x09EA, 0x0229); return end
  if py < 0x024E then walkTo(0x09E0, 0x024E); return end
  if py < 0x0280 then walkTo(0x09C0, 0x0290); return end
  if py < 0x0300 then walkTo(0x09A0, 0x0320); return end
  walkTo(0x0980, 0x0380)
end
"""

proc main() =
  runFrom("south_walk_outdoor", "bin/states/llm/post_knock_outdoor.state", SouthRoadPol, 10000)
  runFrom("follow_route_outdoor", "bin/states/llm/post_knock_outdoor.state", FollowRoutePol, 8000)
  runFrom("rejoin_corridor", "bin/states/llm/frank_corridor.state", RejoinRoadPol, 8000)

when isMainModule: main()
