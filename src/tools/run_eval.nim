## Autoresearch eval runner for the llm-play track (docs/EVAL.md,
## docs/autoresearch-llm-play.md). Screen tier: segmented canary — score
## known fixtures directly against baseline.ref, run the referee test
## subset, then a short scripted turbo walk; write the scorecard to
## runs/<utc>-<idea>/scorecard.json and print the one-line gate summary.
##
## Exit codes: 0 = ran + scorecard written (decision may still be discard);
## 2 = missing assets (ROM/fixtures — regenerate, harness NOT broken);
## 1 = harness broken (canary regressed, referee red, or incomplete card).
##
## Usage: nim r src/tools/run_eval.nim [--idea NAME] [--confirm]
##   [--skip-walk] [--runs-dir PATH] [rom]

import
  std/[json, os, osproc, strformat, strutils],
  ../decompbound/[cpu, snesbus, save_state, policy],
  ./[eval_scorecard, story_percents, touch_grass]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  BaselineRef = "baseline.ref"
  RunsDir = "runs"
  WalkFrames = 200_000
    ## Screen-tier scripted walk budget (bedroom → pokey → knock soft spine).
  NimBuildFlags = "--hints:off --warnings:off --parallelBuild:4 -d:release"
    ## Resource discipline (make-test-ram-blowup lesson): --parallelBuild:4
    ## caps the C-backend fan-out (bare nim spawns nproc cc1 processes) and
    ## -d:release keeps emulation walks fast (debug is ~10x slower). Each
    ## helper is compiled ONCE below and then executed as a plain binary —
    ## eval must never recompile per run.
  WalkerBin = "bin/eval_llm_walker"
    ## Compiled-once llm_ai (-d:noWindow, release) used for every walk.
  RefereeTests = [
    "tests/e2e_knock_complete.nim",
    "tests/test_eval_scorecard.nim",
  ]
    ## The referee_green subset: fast, ROM-light gate tests. Full `make test`
    ## stays a confirm-tier / CI concern (docs/EVAL.md).
  FixtureGates = [
    (fixture: "bin/states/llm/bedroom.state", gate: "tg"),
    (fixture: "bin/states/llm/pokey_done.state", gate: "pokey"),
    (fixture: "bin/states/llm/pre_knock_bed.state", gate: "knock"),
  ]
    ## Segmented canary part 1: each fixture must still score its pinned
    ## percent through the sacred scorer (cheap, no emulation).
  ChainGates = [
    (name: "tg", ceiling: 100),
    (name: "pokey", ceiling: 100),
    (name: "knock", ceiling: 80),
    (name: "buzzbuzz", ceiling: 90),
    (name: "sunrise", ceiling: 90),
    (name: "frank", ceiling: 100),
    (name: "giant", ceiling: 100),
    (name: "captain", ceiling: 100),
    (name: "fourside", ceiling: 100),
    (name: "magicant", ceiling: 98),
    (name: "giygas", ceiling: 80),
  ]
    ## The story spine in play order with each gate's LIVE ceiling — the
    ## honest bot-reachable top, not the scorer max (docs/EVAL.md): knock=80
    ## is sleep-blocked, magicant=98 / giygas=80 await flag RE. A gate at its
    ## ceiling counts complete; the chain stops at the first incomplete gate.

proc chainPrimary(walkMax: JsonNode): float =
  ## Chain encoder: 100 per consecutively-complete gate (at its live
  ## ceiling), plus the frontier gate's raw percent. Missing keys score 0 so
  ## older result payloads stay comparable.
  for g in ChainGates:
    let v = if walkMax.hasKey(g.name): walkMax[g.name].getInt() else: 0
    if v >= g.ceiling:
      result += 100.0
    else:
      result += v.float
      return

proc gatePercent(snes: SnesBus, gate: string): int =
  ## Score one named gate through the sacred scorer surface.
  case gate
  of "tg": touchGrassPercent(snes)
  of "pokey": pokeyPercent(snes)
  of "knock": pokeyKnockPercent(snes)
  else:
    raise newException(ValueError, fmt"unknown gate '{gate}'")

proc loadBaseline(): JsonNode =
  ## Read baseline.ref (JSON): pinned commit + expected canary numbers.
  if not fileExists(BaselineRef):
    echo fmt"ERROR: {BaselineRef} not found — run with --pin-baseline first (see docs/EVAL.md)"
    quit(2)
  parseJson(readFile(BaselineRef))

proc checkAssets(romPath: string) =
  ## Presence-check the user-supplied assets; exit 2 (missing asset, not
  ## broken harness) with a regeneration hint when absent.
  var missing: seq[string]
  if not fileExists(romPath):
    missing.add(romPath & "  (user-supplied ROM — see README)")
  for fg in FixtureGates:
    if not fileExists(fg.fixture):
      missing.add(fg.fixture & "  (regenerate: make play / llm_capture_fixture — docs/llm-sequence.md)")
  if missing.len > 0:
    echo "MISSING ASSETS (harness is NOT broken; supply/regenerate these):"
    for m in missing:
      echo "  - ", m
    quit(2)

proc scoreFixtures(romPath: string): JsonNode =
  ## Segmented canary part 1: load each pinned fixture and score its gate.
  result = newJObject()
  let snes = newSnesBus(policy.readRomFile(romPath))
  var c = snes.resetCpu()
  for fg in FixtureGates:
    deserializeState(cast[seq[byte]](readFile(fg.fixture)), snes, c)
    let pct = gatePercent(snes, fg.gate)
    result[fg.gate] = %pct
    echo fmt"fixture {fg.fixture} -> {fg.gate}={pct}"

proc runRefereeTests(): bool =
  ## Segmented canary part 2: the named referee subset must exit 0.
  result = true
  for t in RefereeTests:
    echo fmt"referee: nim r {t}"
    let code = execCmd(fmt"nim r {NimBuildFlags} {t}")
    if code != 0:
      echo fmt"referee RED: {t} exited {code}"
      result = false

proc buildWalker() =
  ## Compile the headless walker binary once per eval session. Every walk
  ## after this is a plain binary exec — no recompiles, no compiler fan-out.
  echo fmt"build: {WalkerBin} (one-time, parallelBuild:4)"
  let code = execCmd(fmt"nim c {NimBuildFlags} -d:noWindow -o:{WalkerBin} src/tools/llm_ai.nim")
  if code != 0:
    echo "walker build FAILED"
    quit(1)

proc runScriptedWalk(romPath, resultPath: string, frames: int): JsonNode =
  ## Segmented canary part 3: short scripted turbo walk from bedroom.
  ## Invokes llm_ai with explicit flags (never the Theater make target) and
  ## reads back the --result-json payload. Campaign seats are banned here:
  ## the canary proves the harness still WALKS.
  let cmd = fmt"{WalkerBin} " &
    fmt"--mock --pilot scripted --tempo turbo --headless --speed 0 " &
    fmt"--frames {frames} --load-state-path bin/states/llm/bedroom.state " &
    fmt"--result-json {quoteShell(resultPath)} {quoteShell(romPath)}"
  echo "walk: ", cmd
  let code = execCmd(cmd)
  if code != 0 or not fileExists(resultPath):
    echo fmt"scripted walk FAILED (exit={code}, result present={fileExists(resultPath)})"
    return nil
  parseJson(readFile(resultPath))

proc gitShortSha(): string =
  ## Current commit for candidate_id; "unknown" outside a git checkout.
  let (output, code) = execCmdEx("git rev-parse --short HEAD")
  if code == 0: output.strip() else: "unknown"

proc pinBaseline(romPath: string) =
  ## Measure the actual canary numbers and write baseline.ref. Deliberate,
  ## promote-time action — never run as part of a candidate eval.
  checkAssets(romPath)
  buildWalker()
  let fixtures = scoreFixtures(romPath)
  let walkResult = getTempDir() / "eval_pin_walk.json"
  let walk = runScriptedWalk(romPath, walkResult, WalkFrames)
  if walk == nil:
    echo "cannot pin baseline: scripted walk failed"
    quit(1)
  let baseline = %*{
    "pinned_commit": gitShortSha(),
    "fixture_gates": fixtures,
    "walk": {
      "frames_budget": WalkFrames,
      "max": walk["max"],
    },
  }
  writeFile(BaselineRef, pretty(baseline) & "\n")
  let walkMax = walk["max"]
  echo fmt"pinned {BaselineRef}: fixtures={fixtures} walk_max={walkMax}"

proc main() =
  ## Screen-tier eval: canary floors, candidate score, scorecard, summary.
  var
    romPath = DefaultRom
    ideaId = "candidate"
    runsDir = RunsDir
    confirm = false
    skipWalk = false
    doPin = false
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--idea" and i < paramCount():
      inc i
      ideaId = paramStr(i)
    elif a.startsWith("--idea="):
      ideaId = a[7..^1]
    elif a == "--runs-dir" and i < paramCount():
      inc i
      runsDir = paramStr(i)
    elif a == "--confirm":
      confirm = true
    elif a == "--skip-walk":
      skipWalk = true
    elif a == "--pin-baseline":
      doPin = true
    elif not a.startsWith("--"):
      romPath = a
    inc i

  if doPin:
    pinBaseline(romPath)
    return

  checkAssets(romPath)
  let baseline = loadBaseline()

  # Floor 1: harness_canary — fixtures still score the pinned numbers.
  var canaryPass = true
  let fixtures = scoreFixtures(romPath)
  for gate, expected in baseline["fixture_gates"].pairs:
    let got = fixtures[gate].getInt()
    if got != expected.getInt():
      echo fmt"CANARY REGRESSED: fixture gate {gate} expected {expected} got {got}"
      canaryPass = false

  # Floor 1 continued: the scripted walk still reaches the pinned latches.
  # The walk IS also the candidate run for the default (harness-change) lane:
  # a candidate that improves the walk shows up as primary > baseline.
  var walkMax: JsonNode = nil
  if not skipWalk:
    buildWalker()
    let walkFrames = if confirm: WalkFrames * 5 else: WalkFrames
    let resultPath = getTempDir() / fmt"eval_walk_{ideaId}.json"
    let walk = runScriptedWalk(romPath, resultPath, walkFrames)
    if walk == nil:
      canaryPass = false
    else:
      walkMax = walk["max"]
      for gate, expected in baseline["walk"]["max"].pairs:
        let got = walkMax[gate].getInt()
        if got < expected.getInt():
          echo fmt"CANARY REGRESSED: walk gate {gate} expected >= {expected} got {got}"
          canaryPass = false

  # Floor 2: referee_green — the named test subset.
  let refereePass = runRefereeTests()

  # Primary (Phase 2 encoder): chain progress from the walk; the fixture
  # knock value remains the degenerate fallback when the walk is skipped.
  let primary =
    if walkMax != nil: chainPrimary(walkMax)
    elif fixtures.hasKey("knock"): fixtures["knock"].getInt().float
    else: 0.0

  # Floor 3: primary_ratchet (champion floor) — the chain primary may never
  # regress vs the pinned baseline walk. New failure classes surface as gate
  # drops, which the canary already vetoes axis-by-axis.
  let championPrimary = chainPrimary(baseline["walk"]["max"])
  let ratchetPass = walkMax == nil or primary >= championPrimary
  if not ratchetPass:
    echo fmt"RATCHET REGRESSED: chain primary {primary:g} < champion {championPrimary:g}"

  var reasonCodes: seq[string]
  var decision = edKeep
  if not canaryPass:
    decision = edDiscard
    reasonCodes.add("fail_canary")
  if not refereePass:
    decision = edDiscard
    reasonCodes.add("fail_referee")
  if not ratchetPass:
    decision = edDiscard
    reasonCodes.add("fail_ratchet")
  if decision == edKeep:
    reasonCodes.add("keep")

  var gates = newJObject()
  for gate, v in fixtures.pairs:
    gates[gate] = v
  var domainExtra = %*{
    "scaffold_tier": "T4",
    "pilot": "scripted",
    "tempo": "turbo",
  }
  if walkMax != nil:
    for gate, v in walkMax.pairs:
      gates["walk_" & gate] = v
    # Reflex telemetry from the walk payload (stall causes feed future
    # ratchet axes; frames-to-gate feeds the speed panel).
    let walkPath = getTempDir() / fmt"eval_walk_{ideaId}.json"
    let walkFull = parseJson(readFile(walkPath))
    domainExtra["stalls"] = %*{
      "text_window": walkFull{"stall_text_window"}.getInt(0),
      "no_progress": walkFull{"stall_no_progress"}.getInt(0),
      "retrace_escapes": walkFull{"retrace_escapes"}.getInt(0),
      "stuck_recoveries": walkFull{"stuck_recoveries"}.getInt(0),
    }
    if walkFull.hasKey("gate_frames"):
      domainExtra["gate_frames"] = walkFull["gate_frames"]
  domainExtra["gates"] = gates

  let card = Scorecard(
    ideaId: ideaId,
    candidateId: gitShortSha(),
    baselineId: baseline["pinned_commit"].getStr(),
    utc: utcStamp(),
    tier: (if confirm: etConfirm else: etScreen),
    primaryName: "max_knock",
    primaryValue: primary,
    higherIsBetter: true,
    hardConstraints: @[
      HardConstraint(name: "harness_canary", pass: canaryPass),
      HardConstraint(name: "referee_green", pass: refereePass),
    ],
    n: 1,
    seedsOrSlate: "scripted-deterministic",
    decision: decision,
    reasonCodes: reasonCodes,
    domainExtra: domainExtra,
  )
  let cardPath = writeScorecard(card, runsDir)
  echo fmt"scorecard: {cardPath}"
  echo summaryLine(card)
  if not canaryPass or not refereePass:
    quit(1)

when isMainModule:
  main()
