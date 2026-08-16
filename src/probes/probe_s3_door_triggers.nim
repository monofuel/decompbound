## Seat at downtown face pixels, hold Up, watch for window/text/indoor.
## Buttons only; no WRAM writes.
import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fixture = "bin/states/llm/frank_downtown.state"
  Seats = [
    (0x09A8, 0x0260), (0x09B0, 0x0260), (0x09B8, 0x0260),
    (0x0984, 0x0240), (0x0988, 0x0240),
    (0x0994, 0x0238), (0x0998, 0x0238),
    (0x09A4, 0x0220), (0x09A8, 0x0220),
    (0x09B4, 0x0218), (0x09B8, 0x0218),
    (0x0974, 0x0258), (0x0978, 0x0258),
    (0x0914, 0x0250), (0x0918, 0x0250),
    (0x0924, 0x0258), (0x0928, 0x0258),
    (0x09C0, 0x0278), (0x09D0, 0x0278), (0x09E0, 0x0278),
    (0x09C0, 0x0280), (0x09A0, 0x0280),
    (0x0A04, 0x0238), (0x0A08, 0x0238),
    (0x0888, 0x0280), (0x08A4, 0x0280),
  ]

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc trySeat(tx, ty: int) =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & DoorEnterSkillLua
  loadChunk(L, skills, "sk")
  let pol = fmt"""
function update()
  if escapeMenu() then return end
  if doorEnter({tx}, {ty}) then return end
  if walkTo then walkTo({tx}, {ty}) else pad.press("Up") end
end
"""
  loadChunk(L, pol, "seat")
  let i = PlayerSlot * SlotIndexStride
  var sawWin = false
  var sawIndoor = false
  var sawText = false
  var endPx = 0
  var endPy = 0
  for f in 1 .. 400:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, img)
    endPx = readU16(snes, WorldXBase + i)
    endPy = readU16(snes, WorldYBase + i)
    let w0 = readU8(snes, 0x8650)
    let w1 = readU8(snes, 0x8654)
    if w0 != 0xFF or w1 != 0xFF:
      sawWin = true
    if endPx >= OutdoorMaxX:
      sawIndoor = true
    if scene.sceneJson(snes).contains("on_screen_text") and
        not scene.sceneJson(snes).contains("\"on_screen_text\":\"\""):
      sawText = true
    if sawIndoor:
      break
  let hit = abs(endPx - tx) + abs(endPy - ty) <= 4
  if sawIndoor or sawWin or sawText:
    echo fmt"HIT seat=(0x{tx:04X},0x{ty:04X}) end=(0x{endPx:04X},0x{endPy:04X}) " &
      fmt"indoor={sawIndoor} win={sawWin} text={sawText} seated={hit} " &
      fmt"fr={frankPercent(snes)} room={currentRoomLabel(snes)}"
    if sawText or sawIndoor:
      echo "  SCENE ", scene.sceneJson(snes)
  else:
    echo fmt"miss seat=(0x{tx:04X},0x{ty:04X}) end=(0x{endPx:04X},0x{endPy:04X}) seated={hit}"

proc main() =
  echo "DOOR_TRIGGERS from frank_downtown (400f/seat)"
  for (tx, ty) in Seats:
    trySeat(tx, ty)

when isMainModule:
  main()
