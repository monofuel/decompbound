## Capture LLM campaign fixtures by replaying seed NavHouse from a start state.
## Default: load bedroom.state, run NavHouse until tg==100, write onett_start.state.
## Manual overrides: --load-state-path, --out, --frames; optional rom positional.
## Usage:
##   nim r src/tools/llm_capture_fixture.nim
##   nim r src/tools/llm_capture_fixture.nim --load-state-path PATH --out PATH --frames N [rom]
## Output stays under bin/ (gitignored). Never commit .state fixtures.

import
  std/[os, strformat, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, lua53, policy],
  ./[touch_grass, llm_mock_policies]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultLoadState = "bin/states/llm/bedroom.state"
  DefaultOutState = "bin/states/llm/onett_start.state"
  DefaultMaxFrames = 4000

proc loadChunk(L: lua53.PState, src: string, label: string) =
  ## Load and exec a Lua chunk; raise with Lua error text on failure.
  let ls = L.loadbuffer(src.cstring, src.len.cint, label.cstring)
  if ls != lua53.OK:
    let msg = $L.toString(-1)
    L.pop(1)
    raise newException(ValueError, &"loadbuffer failed ({label}): {msg}")
  let ps = L.pcall(0, 0, 0)
  if ps != lua53.OK:
    let msg = $L.toString(-1)
    L.pop(1)
    raise newException(ValueError, &"pcall failed ({label}): {msg}")

proc writeStateFile(path: string, snes: SnesBus, cpu: Cpu) =
  ## Serialize emulator state and write bytes to path (creates parent dir).
  let parent = path.parentDir
  if parent.len > 0:
    createDir(parent)
  let data = serializeState(snes, cpu)
  writeFile(path, cast[string](data))

proc parseArgs(): tuple[rom, loadPath, outPath: string, maxFrames: int] =
  ## Parse CLI flags and optional rom path.
  var
    rom = DefaultRom
    loadPath = DefaultLoadState
    outPath = DefaultOutState
    maxFrames = DefaultMaxFrames
    romSet = false
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--load-state-path" and i < paramCount():
      inc i
      loadPath = paramStr(i)
    elif a.startsWith("--load-state-path="):
      loadPath = a["--load-state-path=".len .. ^1]
    elif a == "--out" and i < paramCount():
      inc i
      outPath = paramStr(i)
    elif a.startsWith("--out="):
      outPath = a["--out=".len .. ^1]
    elif a == "--frames" and i < paramCount():
      inc i
      maxFrames = parseInt(paramStr(i))
    elif a.startsWith("--frames="):
      maxFrames = parseInt(a["--frames=".len .. ^1])
    elif a == "--help" or a == "-h":
      echo "usage: nim r src/tools/llm_capture_fixture.nim [--load-state-path P] [--out P] [--frames N] [rom]"
      echo &"  defaults: load={DefaultLoadState} out={DefaultOutState} frames={DefaultMaxFrames}"
      echo "  runs NavHouse seed until touchGrassPercent==100, then serializes the state"
      quit(0)
    elif not a.startsWith("--") and not romSet:
      rom = a
      romSet = true
    else:
      raise newException(ValueError, &"unknown arg: {a}")
    inc i
  (rom, loadPath, outPath, maxFrames)

proc main() =
  ## Boot ROM, load start fixture, drive NavHouse until outdoor, write out state.
  let (romPath, loadPath, outPath, maxFrames) = parseArgs()

  if not fileExists(romPath):
    echo &"ERROR: ROM not found: {romPath}"
    quit(1)
  if not fileExists(loadPath):
    echo &"ERROR: load state not found: {loadPath}"
    quit(1)

  let snes = newSnesBus(policy.readRomFile(romPath))
  var cpu = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(loadPath)), snes, cpu)

  let frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes,
    frameImage: frameImage,
    frameCount: 0,
    joy1: 0'u16,
    targetFps: 0
  )
  let L = lua53.newstate()
  if L == nil:
    raise newException(ValueError, "lua newstate failed")
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)

  let skills = touch_grass.EscapeMenuSkillLua & "\n" & touch_grass.WalkToSkillLua &
    "\n" & touch_grass.WinBattleSkillLua
  loadChunk(L, skills, "skills")
  loadChunk(L, llm_mock_policies.NavHousePolicy, "nav")

  let startTg = touch_grass.touchGrassPercent(snes)
  echo &"loaded {loadPath} tg={startTg} maxFrames={maxFrames}"

  var hitOutside = false
  var hitFrame = -1

  if startTg == 100:
    hitOutside = true
    hitFrame = 0
    echo "already tg=100; writing without further nav"
  else:
    for f in 0 ..< maxFrames:
      ctx.frameCount = f
      let err = policy.runPolicyFrame(L, ctx)
      if err.len > 0 and f mod 200 == 0:
        echo &"policy err f={f}: {err}"
      snes.joy1 = ctx.joy1
      policy.stepOneFrame(snes, cpu, frameImage)

      let tg = touch_grass.touchGrassPercent(snes)
      if tg == 100:
        hitOutside = true
        hitFrame = f
        echo &"HIT OUTSIDE at frame {f}"
        break

      if f > 0 and f mod 500 == 0:
        let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
        let px = touch_grass.readU16(snes, touch_grass.WorldXBase + pidx)
        let py = touch_grass.readU16(snes, touch_grass.WorldYBase + pidx)
        echo &"f={f} tg={tg} pos=({px:04X},{py:04X})"

  # Release inputs so the fixture is not mid-held d-pad.
  snes.joy1 = 0
  ctx.joy1 = 0

  let finalTg = touch_grass.touchGrassPercent(snes)
  if finalTg != 100:
    let pidx = touch_grass.PlayerSlot * touch_grass.SlotIndexStride
    let px = touch_grass.readU16(snes, touch_grass.WorldXBase + pidx)
    let py = touch_grass.readU16(snes, touch_grass.WorldYBase + pidx)
    echo &"ERROR: never reached tg=100 (final tg={finalTg} pos=({px:04X},{py:04X}) frames={maxFrames})"
    quit(1)

  writeStateFile(outPath, snes, cpu)
  let size = getFileSize(outPath)
  echo &"wrote {outPath} size={size} bytes tg={finalTg} hitFrame={hitFrame}"

when isMainModule:
  main()
