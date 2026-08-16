## S3 arcade door hunt from frank_downtown. Buttons only; no WRAM writes.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, scene]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Fixture = "bin/states/llm/frank_downtown.state"
  SpriteGroupBase = 0x2CD6
  SpritePtrBase = 0x29CA
  CollisionPage = 0xE000

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc dumpStart(snes: SnesBus) =
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase + i)
  let py = readU16(snes, WorldYBase + i)
  echo fmt"START pos=(0x{px:04X},0x{py:04X}) fr={frankPercent(snes)} gs={giantStepPercent(snes)} " &
    fmt"$9887={readU8(snes, 0x9887):02X} $99F2={readU8(snes, 0x99F2):02X} room={currentRoomLabel(snes)}"
  echo "ENTITIES slot group ptr pos dist"
  for s in 0 .. 27:
    if s == PlayerSlot: continue
    let si = s * SlotIndexStride
    let x = readU16(snes, WorldXBase + si)
    let y = readU16(snes, WorldYBase + si)
    if (x == 0 and y == 0) or x == 0xFFFF: continue
    let g = readU16(snes, SpriteGroupBase + si)
    let p = readU16(snes, SpritePtrBase + si)
    let d = (abs(x - px) + abs(y - py)) div 8
    echo fmt"  s={s:2} g=0x{g:04X} p=0x{p:04X} pos=(0x{x:04X},0x{y:04X}) dist={d}"
  echo "COLLISION downtown window (non-00 / non-80):"
  for ty in 0x0240 shr 3 .. 0x02B0 shr 3:
    for tx in 0x0860 shr 3 .. 0x0AA0 shr 3:
      let cx = tx and 0x3F
      let cy = ty and 0x3F
      let idx = (cy shl 6) or cx
      let b = readU8(snes, CollisionPage + idx)
      if b != 0x00 and b != 0x80:
        echo fmt"  tile=({tx*8:#06x},{ty*8:#06x}) byte=0x{b:02X}"

proc runHunt(snes: SnesBus; cpu: var Cpu) =
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  let skills = EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & DoorEnterSkillLua &
    "\n" & NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua &
    "\n" & IntentNavSkillLua & "\n" & AdvanceDialogueSkillLua & "\n" & WinBattleSkillLua
  loadChunk(L, skills, "sk")
  const Hunt = """
-- Sweep south faces of downtown buildings; doorEnter at grid seats.
local seats = {
  {0x09C0, 0x0278}, {0x09A8, 0x0278}, {0x0988, 0x0278}, {0x0968, 0x0278},
  {0x0948, 0x0278}, {0x0928, 0x0278}, {0x0908, 0x0278}, {0x08E8, 0x0278},
  {0x09C0, 0x0268}, {0x09A0, 0x0268}, {0x0980, 0x0268}, {0x0960, 0x0268},
  {0x09D8, 0x0258}, {0x09B8, 0x0258}, {0x0998, 0x0258}, {0x0978, 0x0258},
  {0x09E0, 0x0248}, {0x09C0, 0x0248}, {0x09A0, 0x0248}, {0x0980, 0x0248},
  {0x0A00, 0x0270}, {0x0A20, 0x0270}, {0x09F0, 0x0260}, {0x09D0, 0x0260},
}
local si = 1
local hold = 0
function update()
  if escapeMenu() then return end
  if inBattle() then winBattle(); return end
  local px = mem.read(0x0BBE) + 256 * mem.read(0x0BBF)
  local py = mem.read(0x0BFA) + 256 * mem.read(0x0BFB)
  if px >= 0x1C00 then
    pad.press("Up")
    if (frame() % 20) < 4 then pad.press("A") end
    return
  end
  local t = seats[si]
  if t == nil then si = 1; t = seats[1] end
  if doorEnter and doorEnter(t[1], t[2]) then
    hold = hold + 1
    if hold > 140 then
      hold = 0
      si = si + 1
    end
    return
  end
  if walkTo then walkTo(t[1], t[2]) else pad.press("Up") end
  hold = hold + 1
  if hold > 220 then
    hold = 0
    si = si + 1
  end
end
"""
  loadChunk(L, Hunt, "hunt")
  let i = PlayerSlot * SlotIndexStride
  var maxFr = frankPercent(snes)
  var maxGs = giantStepPercent(snes)
  var indoorHits = 0
  var lastPx = readU16(snes, WorldXBase + i)
  var lastPy = readU16(snes, WorldYBase + i)
  for f in 1 .. 18000:
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
      inc indoorHits
      if indoorHits == 1 or f mod 200 == 0:
        echo fmt"INDOOR f={f} pos=(0x{px:04X},0x{py:04X}) from=(0x{lastPx:04X},0x{lastPy:04X}) " &
          fmt"fr={fr} maxFr={maxFr} gs={gs} room={currentRoomLabel(snes)} " &
          fmt"$9887={readU8(snes, 0x9887):02X} $4DBA={readU8(snes, 0x4DBA):02X}"
        echo "SCENE ", scene.sceneJson(snes)
    elif abs(px - lastPx) + abs(py - lastPy) > 0x80:
      echo fmt"TELE f={f} (0x{lastPx:04X},0x{lastPy:04X})->(0x{px:04X},0x{py:04X}) fr={fr}"
    if f mod 3000 == 0:
      echo fmt"  hunt f={f} pos=(0x{px:04X},0x{py:04X}) fr={fr} gs={gs} indoorHits={indoorHits}"
    lastPx = px
    lastPy = py
  echo fmt"HUNT_DONE maxFr={maxFr} maxGs={maxGs} indoorHits={indoorHits} " &
    fmt"end=(0x{lastPx:04X},0x{lastPy:04X}) room={currentRoomLabel(snes)}"

proc main() =
  doAssert fileExists(Rom) and fileExists(Fixture)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Fixture)), snes, cpu)
  dumpStart(snes)
  runHunt(snes, cpu)

when isMainModule:
  main()
