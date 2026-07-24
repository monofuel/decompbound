## Try to free real post_knock by teleporting outdoor + clearing lock candidates.
import
  std/[os, strformat],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]

proc setU16(snes: SnesBus, off, v: int) =
  let ea = 0x7E0000 + off
  snes.bus.mem[ea] = uint8(v and 0xFF)
  snes.bus.mem[ea+1] = uint8((v shr 8) and 0xFF)

proc tryUnlock(label: string; teleport: bool; clearWins: bool; clearGameMode: bool) =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile("bin/states/llm/post_knock.state")), snes, cpu)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let i = PlayerSlot * SlotIndexStride
  if teleport:
    # Outdoor door band from onett_start
    setU16(snes, WorldXBase + i, 0x0A60)
    setU16(snes, WorldYBase + i, 0x0158)
    # also write entity mirror $0B8E/$0BCA if different base
  if clearWins:
    snes.bus.mem[0x7E0000 + 0x8650] = 0xFF
    snes.bus.mem[0x7E0000 + 0x8654] = 0xFF
  if clearGameMode:
    # try common control-lock: game mode / fade / cutscene
    # $5D98-ish varies; probe a few known
    discard
  # settle
  for _ in 0..60:
    snes.joy1 = 0
    policy.stepOneFrame(snes, cpu, img)
  let px0 = readU16(snes, WorldXBase+i)
  let py0 = readU16(snes, WorldYBase+i)
  for _ in 0..120:
    snes.joy1 = 0x0100  # right
    policy.stepOneFrame(snes, cpu, img)
  let px1 = readU16(snes, WorldXBase+i)
  let py1 = readU16(snes, WorldYBase+i)
  echo fmt"{label}: start=(0x{px0:04X},0x{py0:04X}) afterR=(0x{px1:04X},0x{py1:04X}) dx={px1-px0} kn={pokeyKnockPercent(snes)} kc={knockComplete(snes)} $9887={readU8(snes,0x9887):02X}"

proc main() =
  tryUnlock("raw_indoor", false, false, false)
  tryUnlock("clear_wins", false, true, false)
  tryUnlock("teleport_only", true, false, false)
  tryUnlock("teleport+wins", true, true, false)
  # also try copying outdoor free + full flag region from post_knock
  block:
    let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
    var cpu = snes.resetCpu()
    let outdoor = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
    var ocpu = outdoor.resetCpu()
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/onett_start.state")), outdoor, ocpu)
    deserializeState(cast[seq[byte]](readFile("bin/states/llm/post_knock.state")), snes, cpu)
    # copy flag ranges from post_knock into outdoor free state
    for off in 0x9880 .. 0x9FFF:
      outdoor.bus.mem[0x7E0000 + off] = snes.bus.mem[0x7E0000 + off]
    let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
    for _ in 0..30:
      outdoor.joy1 = 0
      policy.stepOneFrame(outdoor, ocpu, img)
    let i = PlayerSlot * SlotIndexStride
    let px0 = readU16(outdoor, WorldXBase+i)
    for _ in 0..120:
      outdoor.joy1 = 0x0100
      policy.stepOneFrame(outdoor, ocpu, img)
    let px1 = readU16(outdoor, WorldXBase+i)
    echo fmt"flag_merge outdoor: pos=(0x{px0:04X},0x{readU16(outdoor,WorldYBase+i):04X}) dx={px1-px0} kn={pokeyKnockPercent(outdoor)} kc={knockComplete(outdoor)} bb={buzzBuzzPercent(outdoor)} $9887={readU8(outdoor,0x9887):02X}"
    if abs(px1-px0) > 4 and knockComplete(outdoor):
      writeFile("bin/states/llm/post_knock_outdoor.state", cast[string](serializeState(outdoor, ocpu)))
      echo "WROTE post_knock_outdoor via flag_merge"

when isMainModule: main()
