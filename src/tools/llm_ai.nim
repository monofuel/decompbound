## LLM-writes-Lua policy player for milestone 2c.
## Two-clock loop: fast clock runs sandboxed Lua update() every frame (drives joy1);
## slow clock periodically asks LLM (or mock) for a fresh/updated Lua policy string
## based on a compact state summary, hot-reloads it, keeps running.
## Uses the exact same load->runPolicyFrame->stepOneFrame->joy1 path as llm_play
## (via shared policy module) so LLM-authored strings are proven equivalent.
## LLM call is swappable: default --mock uses a fixed canned policy for headless verify
## (no API key needed); real path uses openai_leap when --no-mock and key present.
## Usage: nix develop -c nim c -r src/tools/llm_ai.nim -- [--frames N] [--llm-interval K] [--png-every M] [--mock|--no-mock] [rom]
## The harness + API is our code; ROM and any dumps are user-supplied at runtime.

import
  std/[os, strutils, strformat],
  pixie,
  openai_leap,
  ../decompbound/[cpu, ppu, snesbus, lua53, policy]

const
  DefaultFrames = 60
  DefaultLlmInterval = 20
  DefaultPngEvery = 0

type
  PolicyProvider = proc(summary: string, currentLua: string): string

proc mockProvider(summary: string, currentLua: string): string =
  ## Canned fixed policy for verification without API key.
  ## Always returns the same short update() that presses Right on even frames.
  ## This string travels the identical loadbuffer/pcall/runPolicyFrame/joy1 path
  ## that a real LLM response would.
  result = """function update()
  if frame() % 2 == 0 then
    pad.press('Right')
  else
    pad.set('Right', false)
  end
end
"""

proc realProvider(summary: string, currentLua: string): string =
  ## Real LLM call via openai_leap. Expects OPENAI_API_KEY in env (or set via
  ## newOpenAiApi(apiKey=...)). Returns a policy string or falls back to current.
  let openai = newOpenAiApi()
  const SystemPrompt = """You are an expert at writing compact Lua policies that play EarthBound using a sandboxed emulator API.

The policy defines a function update() called once per emulated frame. Output ONLY valid Lua source that starts with 'function update()' and ends with 'end'. No markdown, no prose, no fences.

Available sandbox API (use exactly these names; no os/io/package/debug require or host access):
- frame() -> integer: current frame count
- mem.read(addr) -> 0..255: byte from WRAM ($7E0000+ or plain offset). Read-only, no MMIO side effects.
- screen.width = 256, screen.height = 224
- screen.pixel(x, y) -> {r=0..255, g=0..255, b=0..255}
- pad.press(name): press button this frame. Names: "A","B","X","Y","L","R","Up","Down","Left","Right","Start","Select"
- pad.set(name, bool)

Constraints:
- Keep update() short and simple (under 20 lines ideal).
- Goal: make progress (hold Right or Down to walk/explore, press A to advance text/dialog or menus).
- Use the state summary (frame count, WRAM samples, coarse screen grid) to make decisions.
- Do not assume specific WRAM meanings beyond what the summary labels.

"""
  let userPrompt = fmt"""State summary:
{summary}

Last policy:
{currentLua}

Produce an improved or continued 'function update() ... end' that drives visible progress in the game."""

  var raw: string
  try:
    raw = openai.createChatCompletion("gpt-4o-mini", SystemPrompt, userPrompt)
  except CatchableError as e:
    echo "LLM ERROR: ", e.msg
    openai.close()
    return currentLua
  openai.close()
  var cleaned = raw.strip()
  if cleaned.startsWith("```"):
    var kept: seq[string] = @[]
    for line in cleaned.splitLines():
      if line.strip().startsWith("```"): continue
      kept.add(line)
    cleaned = kept.join("\n").strip()
  if not cleaned.contains("function update"):
    echo "LLM returned no update(); keeping prior policy. head=", cleaned[0 ..< min(80, cleaned.len)]
    return currentLua
  result = cleaned

proc getProvider(useMock: bool): PolicyProvider =
  ## Select mock or real. Mock is default for safe verify without key.
  if useMock:
    return mockProvider
  else:
    return realProvider

proc buildStateSummary(ctx: policy.PolicyContext): string =
  ## Compact text description of game state for the LLM.
  ## Built from direct WRAM reads (via bus, same backing as mem.read) + screen pixels.
  ## frame + handful of WRAM bytes (generic offsets until EB semantics mapped) +
  ## avg brightness + very coarse 4x4 luminance grid.
  let f = ctx.frameCount
  var wramLines = ""
  # TODO: replace these magic offsets with documented EB WRAM labels (player x/y,
  # menu state, action flags, text box active, etc). Hard-coded to bootstrap.
  # Offsets chosen around common low-WRAM areas that often hold live state.
  const SampleOffs = [0x0020, 0x0021, 0x0024, 0x00A0, 0x00A2, 0x0100, 0x0200, 0x0300]
  for off in SampleOffs:
    let ea = 0x7E0000'u32 + off.uint32
    let v = if ea.int < ctx.snes.bus.mem.len: ctx.snes.bus.mem[ea.int].int else: 0
    wramLines.add fmt"  0x{off:04X}: 0x{v:02X}\n"
  # coarse screen
  let img = ctx.frameImage
  var sum = 0
  var cnt = 0
  const G = 4
  var gsum: array[G, array[G, int]]
  let cw = max(1, img.width div G)
  let ch = max(1, img.height div G)
  for y in 0 ..< img.height:
    for x in 0 ..< img.width:
      let c = img[x, y]
      let lum = (c.r.int + c.g.int + c.b.int) div 3
      sum += lum
      inc cnt
      let gx = min(x div cw, G-1)
      let gy = min(y div ch, G-1)
      gsum[gy][gx] += lum
  let avg = if cnt > 0: sum div cnt else: 0
  var grid = "coarse_4x4_lum:\n"
  for gy in 0 ..< G:
    for gx in 0 ..< G:
      let cellCnt = cw * ch
      let ca = if cellCnt > 0: gsum[gy][gx] div cellCnt else: 0
      grid.add fmt"{ca:3} "
    grid.add "\n"
  result = fmt"""frame: {f}
wram_samples (tentative offsets):
{wramLines}screen:
  avg_brightness: {avg}
{grid}"""

proc loadPolicyChunk(L: lua53.PState, src: string, label: string): bool =
  ## Load and exec a Lua chunk that should define global update(). Returns true on success.
  let ls = L.loadbuffer(src.cstring, src.len.cint, label.cstring)
  if ls != lua53.OK:
    echo fmt"loadbuffer failed for {label}: {L.toString(-1)}"
    L.pop(1)
    return false
  let ps = L.pcall(0, 0, 0)
  if ps != lua53.OK:
    echo fmt"pcall exec failed for {label}: {L.toString(-1)}"
    L.pop(1)
    return false
  return true

proc main() =
  ## Boot emulator, obtain initial policy string from provider (mock or LLM),
  ## load it into sandbox, run fast per-frame loop calling update(), periodically
  ## rebuild summary and re-query provider on slow clock, hot-reload new Lua.
  var maxFrames = DefaultFrames
  var llmInterval = DefaultLlmInterval
  var pngEvery = DefaultPngEvery
  var romPath = ""
  var useMock = true
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--frames" and i < paramCount():
      inc i
      maxFrames = parseInt(paramStr(i))
    elif a.startsWith("--frames="):
      maxFrames = parseInt(a[9..^1])
    elif a == "--llm-interval" and i < paramCount():
      inc i
      llmInterval = parseInt(paramStr(i))
    elif a.startsWith("--llm-interval="):
      llmInterval = parseInt(a[15..^1])
    elif a == "--png-every" and i < paramCount():
      inc i
      pngEvery = parseInt(paramStr(i))
    elif a.startsWith("--png-every="):
      pngEvery = parseInt(a[12..^1])
    elif a == "--no-mock":
      useMock = false
    elif a == "--mock":
      useMock = true
    elif a == "--help" or a == "-h":
      echo "usage: nim c -r src/tools/llm_ai.nim -- [--frames N] [--llm-interval K] [--png-every M] [--mock|--no-mock] [rom]"
      echo "  defaults: --frames 60 --llm-interval 20 ROM=bin/Earthbound (U) [!].smc"
      echo "  --mock (default): use canned policy string, no key needed"
      echo "  --no-mock: call real LLM via openai_leap (needs OPENAI_API_KEY)"
      echo "  To run live: export OPENAI_API_KEY=sk-... ; nix develop -c nim c -r src/tools/llm_ai.nim -- --no-mock --frames 120"
      quit(0)
    elif romPath.len == 0 and not a.startsWith("--"):
      romPath = a
    inc i
  if romPath.len == 0:
    romPath = "bin/Earthbound (U) [!].smc"

  echo fmt"llm_ai: ROM={romPath} frames={maxFrames} llmInterval={llmInterval} pngEvery={pngEvery} mock={useMock}"
  createDir("bin")

  let rom = policy.readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()

  let frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = policy.PolicyContext(
    snes: snes,
    frameImage: frameImage,
    frameCount: 0,
    joy1: 0'u16
  )

  let L = lua53.newstate()
  if L == nil:
    echo "ERROR: lua newstate nil"
    quit(1)
  L.openSandbox()
  policy.setupPolicyApi(L, ctx)

  let provider = getProvider(useMock)

  # Seed: ask provider for the initial policy using frame-0 state.
  var currentPolicy = "function update() end"
  let initSummary = buildStateSummary(ctx)
  currentPolicy = provider(initSummary, currentPolicy)
  echo "initial policy from provider (len=", currentPolicy.len, ")"
  if not loadPolicyChunk(L, currentPolicy, "initial"):
    echo "failed to load initial policy; abort"
    quit(1)

  echo "starting two-clock loop (fast: per-frame update; slow: LLM every ", llmInterval, " frames)"

  for _ in 0 ..< maxFrames:
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0:
      echo fmt"policy runtime error frame {ctx.frameCount}: {err}"

    snes.joy1 = ctx.joy1
    if (ctx.joy1 and policy.BtnRight) != 0:
      echo fmt"  joy1 has RIGHT bit (0x{ctx.joy1:04x}) frame {ctx.frameCount}"

    policy.stepOneFrame(snes, cpu, frameImage)
    ctx.frameCount += 1

    if pngEvery > 0 and (ctx.frameCount mod pngEvery == 0):
      let p = fmt"bin/llm_ai_frame_{ctx.frameCount:04d}.png"
      frameImage.writeFile(p)
      echo fmt"  wrote {p}"

    # Slow clock: re-query provider with fresh summary, hot-reload if changed.
    if llmInterval > 0 and (ctx.frameCount mod llmInterval == 0) and ctx.frameCount > 0:
      let summary = buildStateSummary(ctx)
      let newPolicy = provider(summary, currentPolicy)
      if newPolicy.len > 10 and newPolicy != currentPolicy:
        currentPolicy = newPolicy
        if loadPolicyChunk(L, currentPolicy, fmt"frame_{ctx.frameCount}"):
          echo fmt"  policy reloaded at frame {ctx.frameCount}"
        # else keep running with previous (already defined)

    if cpu.stopped:
      echo "cpu stopped; ending run"
      break

  echo fmt"done: ran {ctx.frameCount} frames. final joy1=0x{snes.joy1:04x}"
  L.close()
  quit(0)

when isMainModule:
  main()
