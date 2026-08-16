## S3: walk Up into downtown building faces while strafing. Buttons only.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fixture = "bin/states/llm/frank_downtown.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc runPol(snes: SnesBus; cpu: var Cpu; pol: string; frames: int; label: string) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & DoorEnterSkillLua &
    "\n" & NavSkillLua & "\n" & IntentNavSkillLua & "\n" & AdvanceDialogueSkillLua &
    "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  loadChunk(L, pol, label)
  let i = PlayerSlot * SlotIndexStride
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  var indoor = 0
  var lastPx = readU16(snes, WorldXBase + i)
  var lastPy = readU16(snes, WorldYBase + i)
  for f in 1 .. frames:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    let px = readU16(snes, WorldXBase + i)
    let py = readU16(snes, WorldYBase + i)
    let fr = frankPercent(snes)
    let gs = giantStepPercent(snes)
    if fr > maxFr: maxFr = fr
    if gs > maxGs: maxGs = gs
    if px >= OutdoorMaxX:
      inc indoor
      if indoor == 1:
        echo fmt"INDOOR {label} f={f} pos=(0x{px:04X},0x{py:04X}) from=(0x{lastPx:04X},0x{lastPy:04X})"
        echo "SCENE ", scene.sceneJson(snes)
    if f mod 2000 == 0:
      echo fmt"  {label} f={f} pos=(0x{px:04X},0x{py:04X}) fr={fr} gs={gs} indoor={indoor} " &
        fmt"$8650={readU8(snes, 0x8650):02X} $10E5={readU8(snes, 0x10E5):02X}"
    lastPx = px
    lastPy = py
  echo fmt"FINAL {label} maxFr={maxFr} maxGs={maxGs} indoor={indoor} " &
    fmt"end=(0x{lastPx:04X},0x{lastPy:04X}) room={currentRoomLabel(snes)}"

proc main() =
  doAssert fileExists(Rom) and fileExists(Fixture)
  let pol = """
-- Hold Up into building faces; strafe X across downtown. Talk if adjacent.
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    pad.press("Up")
    if (frame() % 16) < 4 then pad.press("A") end
    return
  end
  -- Reach sidewalk just south of buildings, then sweep + Up.
  if py > 0x0278 then
    pad.press("Up")
    return
  end
  if py < 0x0248 then
    pad.press("Down")
    return
  end
  local f = frame() % 240
  pad.press("Up")
  if f < 90 then pad.press("Left")
  elseif f < 180 then pad.press("Right")
  elseif f < 200 then pad.press("A")
  else
    if talk then talk() else pad.press("A") end
  end
end
"""
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), snes, cpu)
  echo fmt"START fr={frankPercent(snes)} gs={giantStepPercent(snes)}"
  runPol(snes, cpu, pol, 8000, "strafe_up")

when isMainModule:
  main()
