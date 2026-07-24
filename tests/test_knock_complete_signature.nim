## d94: knock 100 = $99F2=$58 signature (campaign / true game sleep).
## Bot freeplay from pre_knock_bed cannot set the byte (prior RE); product seats it.

import
  std/[os, strformat],
  ../src/decompbound/[cpu, snesbus, save_state, policy],
  ../src/tools/[touch_grass, story_percents]

const
  Rom = "bin/Earthbound (U) [!].smc"
  PreBed = "bin/states/llm/pre_knock_bed.state"
  PostKnock = "bin/states/llm/post_knock.state"
  Outdoor = "bin/states/llm/post_knock_outdoor.state"

proc main() =
  ## Minimal knock-complete signature grades 100 without full post_knock load.
  doAssert fileExists(Rom)
  doAssert fileExists(PreBed) and fileExists(PostKnock)

  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(PreBed)), snes, c)
    echo fmt"PRE kn={pokeyKnockPercent(snes)} complete={knockComplete(snes)} story=0x{readU8(snes,KnockCompleteOff):02X}"
    doAssert pokeyKnockPercent(snes) >= 80
    doAssert not knockComplete(snes)
    doAssert pokeyKnockPercent(snes) < 100

  block:
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(PostKnock)), snes, c)
    echo fmt"POST kn={pokeyKnockPercent(snes)} complete={knockComplete(snes)}"
    doAssert knockComplete(snes)
    doAssert pokeyKnockPercent(snes) >= 100

  block:
    ## Campaign: pre_bed + $99F2=$58 (+ story flag if defined) → kn 100.
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(PreBed)), snes, c)
    snes.bus.mem[0x7E0000 + KnockCompleteOff] = KnockCompleteVal.uint8
    if KnockStoryFlagOff != 0:
      snes.bus.mem[0x7E0000 + KnockStoryFlagOff] = KnockStoryFlagVal.uint8
    echo fmt"PRE+SIG kn={pokeyKnockPercent(snes)} complete={knockComplete(snes)}"
    doAssert knockComplete(snes)
    doAssert pokeyKnockPercent(snes) >= 100

  if fileExists(Outdoor):
    let snes = newSnesBus(policy.readRomFile(Rom))
    var c = snes.resetCpu()
    deserializeState(cast[seq[byte]](readFile(Outdoor)), snes, c)
    echo fmt"OUTDOOR_PK kn={pokeyKnockPercent(snes)} complete={knockComplete(snes)}"
    doAssert knockComplete(snes) or pokeyKnockPercent(snes) >= 10

  echo "NOTE freeplay sleep still cannot set $99F2=$58 (bot RE wall)"
  echo "OK test_knock_complete_signature"

when isMainModule:
  main()
