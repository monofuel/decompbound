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
  ../decompbound/[cpu, ppu, snesbus, lua53]

from std/strformat import fmt

const
  DefaultFrames = 300
  InstrPerLine = 40

  # SNES joypad bitmasks (match play.nim layout for compatibility).
  BtnB = 0x8000'u16
  BtnY = 0x4000'u16
  BtnSel = 0x2000'u16
  BtnStart = 0x1000'u16
  BtnUp = 0x0800'u16
  BtnDown = 0x0400'u16
  BtnLeft = 0x0200'u16
  BtnRight = 0x0100'u16
  BtnA = 0x0080'u16
  BtnX = 0x0040'u16
  BtnL = 0x0020'u16
  BtnR = 0x0010'u16

  # Key under which we store the PolicyContext pointer in the Lua registry.
  CtxRegKey = "db_policy_ctx"

proc readRomFile(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc nameToMask(name: string): uint16 =
  ## Map button name (case-insensitive) to the joy1 bit. Unknown names are 0 (no-op).
  let n = name.toLowerAscii().strip()
  case n:
  of "b": return BtnB
  of "y": return BtnY
  of "select", "sel": return BtnSel
  of "start": return BtnStart
  of "up": return BtnUp
  of "down": return BtnDown
  of "left": return BtnLeft
  of "right": return BtnRight
  of "a": return BtnA
  of "x": return BtnX
  of "l": return BtnL
  of "r": return BtnR
  else: return 0

type
  PolicyContext = ref object
    ## Per-run context passed to Lua callbacks via registry lightuserdata.
    snes*: SnesBus
    frameImage*: Image
    frameCount*: int
    joy1*: uint16

proc countHook(L: lua53.PState, ar: pointer) {.cdecl.} =
  ## Debug hook installed around each update() call. Errors out of the pcall
  ## if the policy runs too many instructions (sandbox CPU bound).
  L.pushstring("policy update interrupted by debug hook after instruction limit".cstring)
  discard L.error()

proc getPolicyCtx(L: lua53.PState): PolicyContext {.inline.} =
  ## Retrieve the PolicyContext stored in the Lua registry by setup.
  L.getfield(lua53.RegistryIndex.cint, CtxRegKey.cstring)
  let p = L.touserdata(-1)
  L.pop(1)
  cast[PolicyContext](p)

proc memRead(L: lua53.PState): cint {.cdecl.} =
  ## Lua binding: mem.read(addr) returns byte from WRAM only (read-only).
  ## Accepts either offset into $7E0000 or full 24-bit address in $7E/$7F.
  ## Outside WRAM returns 0 (no MMIO side effects, per design).
  let ctx = getPolicyCtx(L)
  var a = L.toInteger(1).int
  let eff = if (a and 0xFF0000) in [0x7E0000, 0x7F0000]:
      a and 0xFFFFFF
    else:
      0x7E0000 or (a and 0x1FFFF)
  if eff < 0 or eff >= ctx.snes.bus.mem.len:
    L.pushinteger(0)
    return 1
  L.pushinteger(ctx.snes.bus.mem[eff].int)
  return 1

proc screenPixel(L: lua53.PState): cint {.cdecl.} =
  ## Lua binding: screen.pixel(x, y) -> {r,g,b} table from current framebuffer.
  ## screen.width / screen.height are numbers on the table.
  let ctx = getPolicyCtx(L)
  let x = L.toInteger(1).int
  let y = L.toInteger(2).int
  if x < 0 or x >= ppu.ScreenWidth or y < 0 or y >= ppu.ScreenHeight:
    L.newtable()
    L.pushinteger(0); L.setfield(-2, "r".cstring)
    L.pushinteger(0); L.setfield(-2, "g".cstring)
    L.pushinteger(0); L.setfield(-2, "b".cstring)
    return 1
  let c = ctx.frameImage[x, y]
  L.newtable()
  L.pushinteger(c.r.int); L.setfield(-2, "r".cstring)
  L.pushinteger(c.g.int); L.setfield(-2, "g".cstring)
  L.pushinteger(c.b.int); L.setfield(-2, "b".cstring)
  return 1

proc padSet(L: lua53.PState): cint {.cdecl.} =
  ## Lua: pad.set("Right", true) or pad.set("A", false). ORs/clears into joy1 for next frame.
  let ctx = getPolicyCtx(L)
  let btn = L.toString(1)
  let on = L.toBool(2)
  let mask = nameToMask(btn)
  if mask != 0:
    if on:
      ctx.joy1 = ctx.joy1 or mask
    else:
      ctx.joy1 = ctx.joy1 and (not mask)
  return 0

proc padPress(L: lua53.PState): cint {.cdecl.} =
  ## Lua: pad.press("A") is shorthand for set true (for this next frame).
  let ctx = getPolicyCtx(L)
  let btn = L.toString(1)
  ctx.joy1 = ctx.joy1 or nameToMask(btn)
  return 0

proc frameGetter(L: lua53.PState): cint {.cdecl.} =
  ## Lua: frame() -> current frame count (starts at 0 before first step).
  let ctx = getPolicyCtx(L)
  L.pushinteger(ctx.frameCount)
  return 1

proc setupPolicyApi(L: lua53.PState, ctx: PolicyContext) =
  ## Expose the read-only + input-only sandboxed surface to Lua.
  ## mem.read, screen.{width,height,pixel}, pad.{set,press}, frame.
  # Store ctx in Lua registry under string key so callbacks can retrieve without upvalues.
  L.pushlightuserdata(cast[pointer](ctx))
  L.setfield(lua53.RegistryIndex.cint, CtxRegKey.cstring)
  # mem
  L.newtable()
  L.pushcfunction(memRead)
  L.setfield(-2, "read".cstring)
  L.setglobal("mem".cstring)
  # screen
  L.newtable()
  L.pushinteger(ppu.ScreenWidth)
  L.setfield(-2, "width".cstring)
  L.pushinteger(ppu.ScreenHeight)
  L.setfield(-2, "height".cstring)
  L.pushcfunction(screenPixel)
  L.setfield(-2, "pixel".cstring)
  L.setglobal("screen".cstring)
  # pad
  L.newtable()
  L.pushcfunction(padSet)
  L.setfield(-2, "set".cstring)
  L.pushcfunction(padPress)
  L.setfield(-2, "press".cstring)
  L.setglobal("pad".cstring)
  # frame
  L.pushcfunction(frameGetter)
  L.setglobal("frame".cstring)

proc stepOneFrame(snes: SnesBus, cpu: var Cpu, image: Image) =
  ## Advance the emulator by exactly one frame (262 scanlines), render to image.
  ## Mirrors the core stepping from play.nim (NMI at line 224, InstrPerLine=40).
  let forceBlank = (snes.ppuRegs[0x00] and 0x80) != 0
  if not forceBlank:
    let backdrop = ppu.bgr555ToColor(snes.cgram[0])
    image.fill(backdrop)
  var l = 0
  while l < 262:
    if l == 224 and (snes.nmitimen and 0x80) != 0:
      cpu.nmiPending = true
    for i in 0 ..< InstrPerLine:
      cpu.step(snes.bus)
      if cpu.stopped:
        break
    if l < 224:
      snes.runHdma()
      if (snes.ppuRegs[0x00] and 0x80) == 0:
        ppu.renderScanline(snes, image, l)
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc l
    if l >= 262:
      snes.initHdma()
      break
  ppu.renderSprites(snes, image)
  ppu.overlayForegroundBg(snes, image)

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

  let rom = readRomFile(romPath)
  let snes = newSnesBus(rom)
  var cpu = snes.resetCpu()
  snes.initHdma()

  let frameImage = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let ctx = PolicyContext(
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
  setupPolicyApi(L, ctx)

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
    ctx.joy1 = 0'u16

    L.sethook(countHook, lua53.MASKCOUNT, 20000.cint)
    L.getglobal("update".cstring)
    var callStatus = lua53.OK
    if L.getType(-1) != lua53.TFUNCTION:
      echo "ERROR: no update() function exported by policy"
      L.pop(1)
      break
    callStatus = L.pcall(0, 0, 0)
    L.sethook(cast[lua53.Hook](nil), 0.cint, 0.cint)

    if callStatus != lua53.OK:
      let msg = L.toString(-1)
      L.pop(1)
      echo fmt"policy runtime error frame {ctx.frameCount}: {msg}"
      # fall through with joy1=0 this frame

    snes.joy1 = ctx.joy1
    if (ctx.joy1 and BtnRight) != 0:
      echo fmt"  joy1 has RIGHT bit (0x{ctx.joy1:04x}) frame {ctx.frameCount}"

    stepOneFrame(snes, cpu, frameImage)
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
