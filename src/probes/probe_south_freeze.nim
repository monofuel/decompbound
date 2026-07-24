## d85: south-commercial freeze after continuous outdoor fr90.
## Compare free giant_approach vs frozen frank seat outside $98xx flags.

import
  std/[os, strformat, strutils, algorithm],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ../tools/[touch_grass, story_percents, llm_mock_policies]

const
  Rom = "bin/Earthbound (U) [!].smc"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"
  Giant = "bin/states/llm/giant_approach.state"

proc loadChunk(L: lua53.PState; src, label: string) =
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc skills(): string =
  EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & NavSkillLua & "\n" &
    FollowTrailSkillLua & "\n" & NamedRoutesLua & "\n" & WinBattleSkillLua & "\n" &
    AdvanceDialogueSkillLua & "\n" & IntentNavSkillLua

proc dumpKeys(snes: SnesBus; tag: string) =
  let i = PlayerSlot * SlotIndexStride
  echo fmt"--- {tag} pos=(0x{readU16(snes,WorldXBase+i):04X},0x{readU16(snes,WorldYBase+i):04X}) ---"
  for off in [
    0x0024, 0x4DBA, 0x5D98, 0x5E06, 0x5E07, 0x5E08, 0x5E09,
    0x8650, 0x8654, 0x8958, 0x9871, 0x9875, 0x9876, 0x9877, 0x9878,
    0x9885, 0x9887, 0x99F2,
    0x0BBE, 0x0BBF, 0x0BFA, 0x0BFB,  # pos LE
    0x0B8E, 0x0BCA,  # entity base region
  ]:
    echo fmt"  ${off:04X}={readU8(snes,off):02X}"
  # player slot entity block (slot 24 = index 0x30 stride 0x22)
  echo "  entity slot24 (0x22 bytes @ WorldX):"
  let base = WorldXBase + i
  var line = "   "
  for o in 0 ..< 0x22:
    line.add fmt"{readU8(snes, base + o):02X} "
  echo line

proc tryMove(snes: SnesBus; c: var Cpu; img: Image; tag: string; joy: uint16; frames: int) =
  let i = PlayerSlot * SlotIndexStride
  let px0 = readU16(snes, WorldXBase + i)
  let py0 = readU16(snes, WorldYBase + i)
  for f in 1 .. frames:
    snes.joy1 = joy
    policy.stepOneFrame(snes, c, img)
  let px1 = readU16(snes, WorldXBase + i)
  let py1 = readU16(snes, WorldYBase + i)
  echo fmt"  {tag} span={abs(int(px1)-int(px0))+abs(int(py1)-int(py0))} end=(0x{px1:04X},0x{py1:04X})"

proc freezeFromOutdoor(): (SnesBus, Cpu) =
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
  snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
  snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)
  loadChunk(L, skills(), "sk")
  loadChunk(L, AgentFrankPolicy, "frank")
  for f in 1 .. 5000:
    ctx.frameCount = f
    discard policy.runPolicyFrame(L, ctx)
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    if frankPercent(snes) >= 90 and f > 1500:
      break
  (snes, c)

proc main() =
  doAssert fileExists(Rom) and fileExists(Outdoor) and fileExists(Giant)
  echo "=== d85 south freeze deep RE ==="

  let fre = newSnesBus(policy.readRomFile(Rom))
  var cf = fre.resetCpu()
  deserializeState(cast[seq[byte]](readFile(Giant)), fre, cf)
  dumpKeys(fre, "free giant_approach")
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  tryMove(fre, cf, img, "free Right", 0x0100'u16, 200)

  echo "building freeze seat..."
  var (snes, c) = freezeFromOutdoor()
  dumpKeys(snes, "freeze after frank fr90")
  tryMove(snes, c, img, "freeze Left", 0x0200'u16, 200)

  # Diff entity/player region 0x0B00..0x0D00
  echo "--- entity region diffs 0x0B00..0x0D00 ---"
  var n = 0
  for off in 0x0B00 .. 0x0CFF:
    let a = readU8(snes, off)
    let b = readU8(fre, off)
    if a != b:
      # skip pure pos if we want, but show all first
      if n < 80:
        echo fmt"  ${off:04X}: freeze={a:02X} free={b:02X}"
      n += 1
  echo "entity_diff_count=", n

  # Diff game-mode region 0x5D00..0x5F00
  echo "--- mode region 0x5D00..0x5F00 ---"
  n = 0
  for off in 0x5D00 .. 0x5EFF:
    let a = readU8(snes, off)
    let b = readU8(fre, off)
    if a != b:
      if n < 40:
        echo fmt"  ${off:04X}: freeze={a:02X} free={b:02X}"
      n += 1
  echo "mode_diff_count=", n

  # Diff low WRAM 0x0000..0x0100
  echo "--- low WRAM 0x0000..0x00FF ---"
  n = 0
  for off in 0x0000 .. 0x00FF:
    let a = readU8(snes, off)
    let b = readU8(fre, off)
    if a != b:
      if n < 30:
        echo fmt"  ${off:04X}: freeze={a:02X} free={b:02X}"
      n += 1
  echo "low_diff_count=", n

  # Unlock attempts: overlay free mode + entity control-ish + windows
  for off in [0x5E06, 0x5E07, 0x5E08, 0x5E09, 0x5D98, 0x0024, 0x9871]:
    snes.bus.mem[0x7E0000 + off] = uint8(readU8(fre, off))
  snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  snes.bus.mem[0x7E0000 + 0x8958] = 0xFF
  snes.bus.mem[0x7E0000 + 0x9877] = uint8(readU8(snes, 0x9877)) and 0xFE'u8
  tryMove(snes, c, img, "mode+win unlock Left", 0x0200'u16, 300)

  # Overlay free entity slot24 block (0x22 bytes at WorldX)
  let bi = PlayerSlot * SlotIndexStride
  # keep freeze pos, copy other entity fields from free relative? better: copy free entity then restore pos
  let fpx = readU16(snes, WorldXBase + bi)
  let fpy = readU16(snes, WorldYBase + bi)
  for o in 0 ..< 0x40:
    snes.bus.mem[0x7E0000 + WorldXBase + bi + o] = uint8(readU8(fre, WorldXBase + bi + o))
  snes.bus.mem[0x7E0000 + WorldXBase + bi] = uint8(fpx and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + bi + 1] = uint8(fpx shr 8)
  snes.bus.mem[0x7E0000 + WorldYBase + bi] = uint8(fpy and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + bi + 1] = uint8(fpy shr 8)
  tryMove(snes, c, img, "entity block overlay Left", 0x0200'u16, 300)

  # Overlay free hitbox type / nav player fields from policy.nim notes
  # Entity hitbox type array $2B6E,X; player slot 24 → index 0x30
  for o in 0 .. 0x40:
    snes.bus.mem[0x7E0000 + 0x2B6E + o] = uint8(readU8(fre, 0x2B6E + o))
  tryMove(snes, c, img, "hitbox overlay Left", 0x0200'u16, 300)

  # Full free entity region 0x0B00..0x0CFF except pos
  for off in 0x0B00 .. 0x0CFF:
    if off == WorldXBase + bi or off == WorldXBase + bi + 1 or
       off == WorldYBase + bi or off == WorldYBase + bi + 1:
      continue
    snes.bus.mem[0x7E0000 + off] = uint8(readU8(fre, off))
  snes.bus.mem[0x7E0000 + WorldXBase + bi] = uint8(fpx and 0xFF)
  snes.bus.mem[0x7E0000 + WorldXBase + bi + 1] = uint8(fpx shr 8)
  snes.bus.mem[0x7E0000 + WorldYBase + bi] = uint8(fpy and 0xFF)
  snes.bus.mem[0x7E0000 + WorldYBase + bi + 1] = uint8(fpy shr 8)
  tryMove(snes, c, img, "full entity region Left", 0x0200'u16, 300)

  # Reseat to free giant coords after entity overlay
  snes.bus.mem[0x7E0000 + WorldXBase + bi] = 0xF0
  snes.bus.mem[0x7E0000 + WorldXBase + bi + 1] = 0x08
  snes.bus.mem[0x7E0000 + WorldYBase + bi] = 0x81
  snes.bus.mem[0x7E0000 + WorldYBase + bi + 1] = 0x02
  for f in 1 .. 20:
    snes.joy1 = 0
    policy.stepOneFrame(snes, c, img)
  tryMove(snes, c, img, "entity+giantpos Right", 0x0100'u16, 300)

  echo "OK probe_south_freeze"

when isMainModule:
  main()
