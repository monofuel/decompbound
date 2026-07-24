## Probe Ticket D: -- LEARN write-router + secret knowledge/npcs injection.
##
## (a) Routes a sample `-- LEARN npc:pokey ...` into decompbound_secret/knowledge/npcs/pokey.md.
## (b) Loads home_door.state and shows Mom KB bullets injected into the state summary.
import
  std/[os, strutils, sequtils],
  ../decompbound/[snesbus, save_state, policy],
  ./llm_ai

const
  RomPath = "bin/Earthbound (U) [!].smc"
  HomeDoorState = "bin/states/llm/home_door.state"
  PokeyKb = "../decompbound_secret/knowledge/npcs/pokey.md"
  SampleLearn = "-- LEARN npc:pokey he takes credit for your work"

proc section(title: string) =
  ## Print a labeled section header for probe output.
  echo ""
  echo "==== ", title, " ===="

proc main() =
  ## Run LEARN router + home_door knowledge injection smoke checks.
  section("(a) BEFORE learn route — secret knowledge/npcs/pokey.md tail")
  if fileExists(PokeyKb):
    let before = readFile(PokeyKb)
    echo before
    echo "(file len=", before.len, ")"
  else:
    echo "(file missing)"

  section("(a) Routing sample LEARN line")
  echo "input: ", SampleLearn
  extractAndAppendLearns(SampleLearn)

  section("(a) AFTER learn route — secret knowledge/npcs/pokey.md")
  let after = readFile(PokeyKb)
  echo after
  if "he takes credit for your work [bot]" in after:
    echo "OK: [bot] bullet present"
  else:
    echo "FAIL: expected [bot] bullet missing"
    quit(1)
  # De-dup: second identical LEARN must not double the bullet.
  extractAndAppendLearns(SampleLearn)
  let afterDup = readFile(PokeyKb)
  let botCount = afterDup.splitLines().filterIt(
    it.strip() == "- he takes credit for your work [bot]").len
  if botCount != 1:
    echo "FAIL: de-dup broken, bot bullet count=", botCount
    quit(1)
  echo "OK: de-dup kept single [bot] bullet (count=1)"

  section("(b) home_door.state — scene names + summary KNOWLEDGE injection")
  if not fileExists(RomPath):
    echo "FAIL: ROM missing at ", RomPath
    quit(1)
  if not fileExists(HomeDoorState):
    echo "FAIL: state missing at ", HomeDoorState
    quit(1)
  let snes = newSnesBus(policy.readRomFile(RomPath))
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(HomeDoorState)), snes, c)
  let kbOnly = knowledgeInjection(snes)
  echo "knowledgeInjection alone:"
  echo if kbOnly.len > 0: kbOnly else: "(empty)"
  let ctx = PolicyContext(snes: snes, frameImage: nil, frameCount: 0)
  let summary = buildStateSummary(ctx)
  echo ""
  echo "--- full summary (excerpt: SCENE + KNOWLEDGE + first progress lines) ---"
  var printed = 0
  for line in summary.splitLines():
    if line.startsWith("SCENE ") or line.startsWith("KNOWLEDGE") or
       line.startsWith("[") or line.startsWith("- ") or
       line.startsWith("touch_grass") or line.startsWith("current_room") or
       line.startsWith(">>> CURRENT"):
      echo line
      inc printed
    elif printed > 0 and printed < 40 and (line.startsWith("pokey") or line.len == 0):
      echo line
      inc printed
  if "KNOWLEDGE (what you know about who's nearby):" notin summary:
    echo "FAIL: KNOWLEDGE block missing from summary"
    quit(1)
  if "[mom]" notin summary:
    echo "FAIL: Mom KB not injected (expected [mom] header)"
    quit(1)
  if "[redacted]" notin summary and "front door" notin summary:
    # Mom bullets mention the door / bed dialogue — either is fine.
    if "Talking to her" notin summary:
      echo "FAIL: Mom bullet facts not present in summary"
      quit(1)
  echo "OK: Mom KB block injected into buildStateSummary"

  section("done")
  echo "probe_memory_router: PASS"

when isMainModule:
  main()
