## Quick story-flag dump across fixtures.
import
  std/[os, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ../tools/[touch_grass, story_percents]
proc r(s: SnesBus, o: int): int = touch_grass.readU8(s, o)
proc main() =
  let snes = newSnesBus(policy.readRomFile("bin/Earthbound (U) [!].smc"))
  var c = snes.resetCpu()
  for f in ["bedroom", "pre_knock_bed", "post_knock", "home_indoor_onett", "home_indoor",
            "pokey_done", "onett_start", "home_natural_entry", "home_downstairs_night"]:
    let p = "bin/states/llm/" & f & ".state"
    if not fileExists(p): continue
    deserializeState(cast[seq[byte]](readFile(p)), snes, c)
    echo fmt"{f}: knock={pokeyKnockPercent(snes)} tg={touchGrassPercent(snes)} room={currentRoomLabel(snes)} 9885={r(snes,0x9885):02X} 99F2={r(snes,0x99F2):02X} 9A0F={r(snes,0x9A0F):02X} 988B={r(snes,0x988B):02X}"
when isMainModule: main()
