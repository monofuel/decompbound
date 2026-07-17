## Headless Lua policy runner for milestone 2b.
## Boots a user ROM, loads a sandboxed Lua policy (defines update()), calls
## update() every frame so the policy can mem.read / screen.pixel / pad.set/press
## / frame(), then applies resulting joy1 and steps exactly one emulated frame.
## --frames N limits run (headless friendly). --png-every K writes periodic
## frame PNGs to bin/ for visual proof without a window.
## Usage: nim r src/tools/llm_play.nim [--frames N] [--png-every K] [rom] [policy.lua]
## The harness + API is our code; ROM and any dumps are user-supplied at runtime.

import
  std/[os, strutils],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, lua53, policy]

from std/strformat import fmt

const
  DefaultFrames = 300



proc main() =
  ## Parse args, boot, sandbox Lua, load policy chunk (defines update), drive frames.
  var maxFrames = DefaultFrames
  var pngEvery = 0
  var romPath = ""
  var policyPath = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--frames" and i < paramCount():
      inc i
      maxFrames = parseInt(paramStr(i))
    elif a.startsWith("--frames="):
      maxFrames = parseInt(a[9..^1])
    elif a == "--png-every" and i < paramCount():
      inc i
      pngEvery = parseInt(paramStr(i))
    elif a.startsWith("--png-every="):
      pngEvery = parseInt(a[12..^1])
    elif a == "--help" or a == "-h":
      echo "usage: nim r src/tools/llm_play.nim [--frames N] [--png-every K] [rom] [policy.lua]"
      echo "  defaults: --frames 300, ROM=bin/Earthbound (U) [!].smc, policy=examples/policy_demo.lua"
      echo "  --png-every 60 will write bin/policy_frame_00xx.png every 60 frames"
      quit(0)
    elif romPath.len == 0 and not a.startsWith("--"):
      romPath = a
    elif policyPath.len == 0 and not a.startsWith("--"):
      policyPath = a
    inc i
  if romPath.len == 0:
    romPath = "bin/Earthbound (U) [!].smc"
  if policyPath.len == 0:
    policyPath = "examples/policy_demo.lua"

  echo fmt"llm_play: ROM={romPath} policy={policyPath} frames={maxFrames} pngEvery={pngEvery}"
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
    echo "ERROR: lua newstate returned nil"
    quit(1)

  L.openSandbox()
  policy.setupPolicyApi(L, ctx)

  let policySrc = readFile(policyPath)
  let loadStatus = L.loadbuffer(policySrc.cstring, policySrc.len.cint, policyPath.cstring)
  if loadStatus != lua53.OK:
    echo fmt"ERROR: loadbuffer failed: {L.toString(-1)}"
    quit(1)

  let initStatus = L.pcall(0, 0, 0)
  if initStatus != lua53.OK:
    echo fmt"ERROR: policy chunk failed: {L.toString(-1)}"
    L.pop(1)
    quit(1)

  echo "policy chunk loaded (expecting global update()); starting frame loop"

  for _ in 0 ..< maxFrames:
    let err = policy.runPolicyFrame(L, ctx)
    if err.len > 0:
      echo fmt"policy runtime error frame {ctx.frameCount}: {err}"
      # joy1 left at 0 by runPolicyFrame

    snes.joy1 = ctx.joy1
    policy.stepOneFrame(snes, cpu, frameImage)
    ctx.frameCount += 1

    if pngEvery > 0 and (ctx.frameCount mod pngEvery == 0):
      let p = fmt"bin/policy_frame_{ctx.frameCount:04d}.png"
      frameImage.writeFile(p)
      echo fmt"  wrote {p}"

    if cpu.stopped:
      echo "cpu stopped; ending run"
      break

  echo fmt"done: ran {ctx.frameCount} frames. final joy1=0x{snes.joy1:04x}"
  L.close()
  quit(0)

when isMainModule:
  main()
