## Compare entity slots + candidate day bytes across fixtures.
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents, scene]

proc dumpEnts(snes: SnesBus, label: string) =
  let i = PlayerSlot * SlotIndexStride
  let px = readU16(snes, WorldXBase+i)
  let py = readU16(snes, WorldYBase+i)
  echo fmt"=== {label} pos=(0x{px:04X},0x{py:04X}) bb={buzzBuzzPercent(snes)} su={sunrisePercent(snes)} fr={frankPercent(snes)} ==="
  echo fmt"  party $988B..={readU8(snes,0x988B):02X},{readU8(snes,0x988C):02X},{readU8(snes,0x988D):02X}"
  echo fmt"  $9885={readU8(snes,0x9885):02X} $9887={readU8(snes,0x9887):02X} $99F2={readU8(snes,0x99F2):02X} sector=$89CA={readU16(snes,0x89CA):04X}"
  # nearby entity slots 0..23 and party 24..27
  var near = 0
  for s in 0 .. 30:
    let si = s * SlotIndexStride
    let ex = readU16(snes, WorldXBase + si)  # wait - WorldXBase is for player slot offset?
    # Entity X at $0B8E+s*2
    let ex2 = readU16(snes, 0x0B8E + s*2)
    let ey2 = readU16(snes, 0x0BCA + s*2)
    if ex2 == 0 and ey2 == 0: continue
    if ex2 == 0xFFFF or ey2 == 0xFFFF: continue
    let d = abs(ex2 - px) + abs(ey2 - py)
    if d < 0x200 or s >= 24:
      let g = readU16(snes, 0x2CD6 + s*2)
      echo fmt"  slot={s} pos=(0x{ex2:04X},0x{ey2:04X}) dist={d} sprGroup=0x{g:04X}"
      if d < 0x80 and s != PlayerSlot: near.inc
  echo fmt"  nearby_slots_dist<0x80: {near}"
  echo "  scene_head=", scene.sceneJson(snes)[0 .. min(280, scene.sceneJson(snes).len-1)]

proc load(path: string): SnesBus =
  result = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var cpu = result.resetCpu()
  deserializeState(cast[seq[byte]](readFile(path)), result, cpu)
  if "post_knock" in path or "buzz" in path or "frank" in path or "giant" in path:
    result.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    result.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8

proc main() =
  for p in ["bin/states/llm/onett_start.state",
            "bin/states/llm/post_knock_outdoor.state",
            "bin/states/llm/buzz_meteor.state",
            "bin/states/llm/frank_downtown.state",
            "bin/states/llm/giant_approach.state",
            "bin/states/llm/post_knock.state"]:
    if fileExists(p):
      dumpEnts(load(p), p)

when isMainModule: main()
