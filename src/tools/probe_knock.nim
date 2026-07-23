## Drive PokeyKnockPolicy from pokey_free → home → bed → knock.
## Prints pokeyKnockPercent transitions and saves milestone fixtures.
## Usage: nim r -d:release src/tools/probe_knock.nim [maxFrames]

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, llm_mock_policies, story_percents]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  FreeState = "bin/states/llm/pokey_free.state"
  HomeDoorOut = "bin/states/llm/home_door.state"
  InBedroomOut = "bin/states/llm/in_bedroom.state"
  NotesPath = "bin/knock_re_notes.txt"

proc loadChunk(L: lua53.PState, src, label: string) =
  ## Load and run a Lua chunk; raise on error.
  if L.loadbuffer(src.cstring, src.len.cint, label.cstring) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))
  if L.pcall(0, 0, 0) != lua53.OK:
    raise newException(ValueError, $L.toString(-1))

proc playerPos(snes: SnesBus): (int, int) =
  ## Slot-24 world position.
  let i = PlayerSlot * SlotIndexStride
  (readU16(snes, WorldXBase + i), readU16(snes, WorldYBase + i))

proc appendNotes(line: string) =
  ## Append one line to the RE notes artifact.
  let f = open(NotesPath, fmAppend)
  f.writeLine(line)
  f.close()

proc dumpFlags(snes: SnesBus, tag: string) =
  ## Print event-flag window around $9880 and dialogue windows.
  let (px, py) = playerPos(snes)
  let w0 = readU8(snes, 0x8650)
  let w1 = readU8(snes, 0x8654)
  echo &"{tag} pos=(0x{px:04X},0x{py:04X}) win0=0x{w0:02X} win1=0x{w1:02X} knock_pct={pokeyKnockPercent(snes)}"
  var s = &"{tag} flags9880.."
  for i in 0x9880 .. 0x98C0:
    s &= &" {readU8(snes, i):02X}"
  echo s

proc snapshotWram(snes: SnesBus): seq[uint8] =
  ## Full 128KB WRAM copy for flagdiff.
  result = newSeq[uint8](0x20000)
  for i in 0 ..< 0x20000:
    result[i] = snes.bus.mem[0x7E0000 + i]

proc quietDiff(a, b: seq[uint8], tag: string) =
  ## Diff quiet WRAM pages (same filter as probe_replay_flagdiff).
  const PageChurnMax = 12
  echo &"--- flagdiff {tag} ---"
  var page = 0
  var total = 0
  while page < a.len:
    let hi = min(page + 256, a.len)
    var idxs: seq[int] = @[]
    for i in page ..< hi:
      if a[i] != b[i]:
        idxs.add i
    if idxs.len > 0 and idxs.len <= PageChurnMax:
      for i in idxs:
        echo &"  $7E{i:05X}: {a[i]:02X} -> {b[i]:02X}"
        inc total
    elif idxs.len > PageChurnMax:
      echo &"  [page $7E{page:05X}: {idxs.len} diffs — churn]"
    page = hi
  echo &"  ({total} quiet-page byte diffs)"

proc main() =
  ## Run knock seed; log grade ladder; save fixtures; optional flagdiff.
  let maxF =
    if paramCount() >= 1: parseInt(paramStr(1))
    else: 18000

  let snes = newSnesBus(policy.readRomFile(DefaultRom))
  var c = snes.resetCpu()
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  deserializeState(cast[seq[byte]](readFile(FreeState)), snes, c)

  let ctx = policy.PolicyContext(
    snes: snes, frameImage: img, frameCount: 0, joy1: 0, targetFps: 0)
  let L = lua53.newstate()
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)

  let skills =
    EscapeMenuSkillLua & "\n" & WalkToSkillLua & "\n" & WinBattleSkillLua &
    "\n" & AdvanceDialogueSkillLua & "\n" & DoorEnterSkillLua & "\n" &
    NavSkillLua & "\n" & FollowTrailSkillLua & "\n" & NamedRoutesLua
  loadChunk(L, skills, "skills")
  loadChunk(L, PokeyKnockPolicy, "knock")

  dumpFlags(snes, "START")
  appendNotes(&"probe_knock START from {FreeState}")

  var lastPct = -1
  var maxPct = 0
  var savedDoor = false
  var savedBed = false
  var preKnock: seq[uint8] = @[]
  var preKnockSet = false
  var knockSeen = false

  for f in 0 ..< maxF:
    ctx.frameCount = f
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0 and f mod 300 == 0:
      echo &"ERR f={f}: {err}"
    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, c, img)

    let (px, py) = playerPos(snes)
    let pct = pokeyKnockPercent(snes)
    let indoor = px >= 0x1C00
    let w1 = readU8(snes, 0x8654)

    if pct != lastPct:
      let line = &"GRADE f={f} knock={pct} pos=(0x{px:04X},0x{py:04X}) indoor={indoor} win1=0x{w1:02X}"
      echo line
      appendNotes(line)
      lastPct = pct
      if pct > maxPct:
        maxPct = pct

    # Milestone fixtures (local only — never git-add).
    if not savedDoor and not indoor and abs(px - 0x0A60) + abs(py - 0x0158) <= 0x20:
      writeFile(HomeDoorOut, cast[string](serializeState(snes, c)))
      echo &"SAVED {HomeDoorOut} f={f}"
      appendNotes(&"SAVED home_door f={f} pos=(0x{px:04X},0x{py:04X})")
      savedDoor = true

    if not savedBed and indoor and px >= 0x1F00 and py >= 0x0300:
      writeFile(InBedroomOut, cast[string](serializeState(snes, c)))
      echo &"SAVED {InBedroomOut} f={f}"
      appendNotes(&"SAVED in_bedroom f={f} pos=(0x{px:04X},0x{py:04X})")
      savedBed = true
      if not preKnockSet:
        preKnock = snapshotWram(snes)
        preKnockSet = true
        echo "pre-knock WRAM snapshot taken (bedroom)"

    # Capture post-knock window open / flag once pct hits 100 or dialogue fires in bed.
    if savedBed and not knockSeen and (pct >= 100 or (w1 != 0xFF and f > 100)):
      if preKnockSet:
        quietDiff(preKnock, snapshotWram(snes), &"bedroom_to_f{f}")
      dumpFlags(snes, &"KNOCK_CANDIDATE f={f}")
      knockSeen = true
      if pct >= 100:
        echo &"KNOCK_ACHIEVED@{f}"
        appendNotes(&"KNOCK_ACHIEVED@{f}")
        break

    if f mod 500 == 0:
      echo &"f={f} pos=(0x{px:04X},0x{py:04X}) knock={pct} indoor={indoor} joy=0x{ctx.joy1:04X}"

  let (fx, fy) = playerPos(snes)
  echo "=== knock probe summary ==="
  echo &"FINAL pos=(0x{fx:04X},0x{fy:04X}) knock={pokeyKnockPercent(snes)} max={maxPct} indoor={fx >= 0x1C00}"
  echo &"fixtures: door={savedDoor} bedroom={savedBed} knockSeen={knockSeen}"
  appendNotes(&"FINAL max={maxPct} knock={pokeyKnockPercent(snes)} pos=(0x{fx:04X},0x{fy:04X})")
  if maxPct >= 100:
    echo "VERIFY: knock_pct 0→100 OK"
  else:
    echo &"VERIFY: incomplete max={maxPct} (need flag RE + seed polish)"

when isMainModule:
  main()
