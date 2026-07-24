## Knock-complete signature ($99F2=$58 on post_knock) grades 100; pre-knock stays 80.
## Buzz/sunrise/frank partial ladders gate on knockComplete.

import
  std/[os, strutils],
  ../src/decompbound/[cpu, snesbus, save_state, policy],
  ../src/tools/[story_percents, touch_grass]

const
  Rom = "bin/Earthbound (U) [!].smc"
  PostKnock = "bin/states/llm/post_knock.state"
  PreKnock = "bin/states/llm/pre_knock_bed.state"
  PokeyDone = "bin/states/llm/pokey_done.state"

proc load(path: string, snes: SnesBus, c: var Cpu) =
  deserializeState(cast[seq[byte]](readFile(path)), snes, c)

proc main() =
  ## Verify knock 100 signature and gated ladders on real fixtures.
  doAssert fileExists(Rom)
  doAssert fileExists(PostKnock)
  doAssert fileExists(PreKnock)
  let snes = newSnesBus(policy.readRomFile(Rom))
  var c = snes.resetCpu()

  load(PreKnock, snes, c)
  doAssert not knockComplete(snes), "pre_knock must not have complete sig"
  doAssert pokeyKnockPercent(snes) == 80, "pre_knock bedroom = 80"
  doAssert buzzBuzzPercent(snes) == 0
  doAssert sunrisePercent(snes) == 0
  doAssert frankPercent(snes) == 0
  echo "pre_knock: knock=80 complete=false (ok)"

  load(PostKnock, snes, c)
  doAssert knockComplete(snes), "post_knock must set $99F2=$58 signature"
  doAssert pokeyKnockPercent(snes) == 100, "post_knock grades 100"
  let bb = buzzBuzzPercent(snes)
  doAssert bb >= 20, "post_knock indoor buzz >= 20, got " & $bb
  doAssert sunrisePercent(snes) >= 10
  echo "post_knock: knock=100 buzz=", bb, " sunrise=", sunrisePercent(snes)

  if fileExists(PokeyDone):
    load(PokeyDone, snes, c)
    doAssert not knockComplete(snes)
    doAssert pokeyKnockPercent(snes) < 100
    echo "pokey_done: knock=", pokeyKnockPercent(snes), " complete=false (ok)"

  echo "OK test_knock_complete"

when isMainModule:
  main()
