## Shared harness primitives for sandboxed Lua policy runners (milestones 2b/2c).
## Joypad masks, PolicyContext, the exact mem/screen/pad/frame bindings,
## setup, update caller, and deterministic one-frame stepper.
## Both llm_play.nim and llm_ai.nim use this so the Lua->joy1 path is identical.
## The harness + API is our code; ROM and any dumps are user-supplied at runtime.

import
  std/strutils,
  pixie,
  ./[cpu, ppu, snesbus, lua53]

const
  InstrPerLine* = 150  # match play.nim's frame budget; at 40 the game is CPU-starved
                       # and never boots past force-blank (black frames in llm_ai/play).

  # SNES joypad bitmasks (match play.nim layout for compatibility).
  BtnB* = 0x8000'u16
  BtnY* = 0x4000'u16
  BtnSel* = 0x2000'u16
  BtnStart* = 0x1000'u16
  BtnUp* = 0x0800'u16
  BtnDown* = 0x0400'u16
  BtnLeft* = 0x0200'u16
  BtnRight* = 0x0100'u16
  BtnA* = 0x0080'u16
  BtnX* = 0x0040'u16
  BtnL* = 0x0020'u16
  BtnR* = 0x0010'u16

  # Key under which we store the PolicyContext pointer in the Lua registry.
  CtxRegKey* = "db_policy_ctx"

  # EB on-screen text (BG nametable tilemap) decode constants.
  # Matches read_text.nim / docs/scripts.md: printable storage = ascii + 0x30,
  # rendered tile = fontBase + ((storage - 0x50) & 0x7F)
  FontTileBases = [0, 0x080, 0x0A0, 0x0A1, 0x0B0, 0x0C0, 0x0CF, 0x0E0, 0x100, 0x180, 0x200, 0x280, 0x2A0, 0x300]
  DialogueRows = [18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28]
  MinTextRun = 3

  # Full-bus sandbox peek (snes.read / snes.readRange). Hardware-port window in
  # system banks must never go through bus.read8 — MMIO reads latch state.
  SnesAddrMask = 0xFFFFFF
  SystemBankMax = 0x3F
  SystemBankHiMin = 0x80
  SystemBankHiMax = 0xBF
  LowRamSize = 0x2000
  MmioWindowLo = 0x2000
  MmioWindowHi = 0x5FFF
  SramWindowLo = 0x6000
  SramWindowHi = 0x7FFF
  SramBankMin = 0x20
  WramMirrorBase = 0x7E0000
  SnesReadRangeMax = 8192

# lua_seti is not wrapped in lua53.nim; bind locally so snes.readRange can fill
# 1-based integer keys without touching the shared binding module.
proc luaSeti(L: lua53.PState, idx: cint, n: lua53.Integer) {.cdecl, importc: "lua_seti".}

proc readRomFile*(filepath: string): seq[uint8] =
  ## Read ROM file and return bytes, stripping a 512-byte copier header if present.
  let data = readFile(filepath)
  var start = 0
  if data.len mod 1024 == 512:
    start = 512
  result = newSeq[uint8](data.len - start)
  for i in 0..<result.len:
    result[i] = data[start + i].uint8

proc nameToMask*(name: string): uint16 =
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

proc glyphToChar(tile: int, fontBase: int): char =
  ## Reverse EB glyph mapping from nametable tile back to ASCII char.
  ## glyph = (storage - 0x50) & 0x7F ; storage = ascii + 0x30 .
  ## Replicated from read_text core (no host/ROM access; pure on snes vram/ppuregs).
  let g = tile - fontBase
  if g < 0 or g > 0x7F:
    return '\0'
  let storage = g + 0x50
  # Storage encoding: printable byte = ascii + 0x30 (verified in docs/scripts.md + text_decode).
  let chVal = storage - 0x30
  if chVal >= 0x20 and chVal <= 0x7E:
    return char(chVal)
  return '\0'

proc decodeWindowText(snes: SnesBus, bg: int, fontBase: int): seq[string] =
  ## Scan the full nametable(s) for this BG, collect printable runs using the glyph map.
  ## Returns candidate lines (trimmed, deduped-ish).
  result = @[]
  let scReg = snes.ppuRegs[0x07 + bg].int
  let tilemapBase = ((scReg shr 2) shl 10) and 0x7FFF
  let sizeBits = scReg and 3
  let wScreens = if (sizeBits and 1) != 0: 2 else: 1
  let hScreens = if (sizeBits and 2) != 0: 2 else: 1
  var seen: seq[string] = @[]
  for sy in 0..<hScreens:
    for sx in 0..<wScreens:
      let mb = tilemapBase + sx * 0x400 + sy * (if sizeBits == 3: 0x800 else: 0x400)
      for row in 0..<32:
        var run = ""
        for col in 0..<32:
          let wi = (mb + row * 32 + col) and 0x7FFF
          if wi >= snes.vram.len: continue
          let entry = snes.vram[wi]
          let tile = (entry and 0x03FF).int
          let ch = glyphToChar(tile, fontBase)
          if ch != '\0':
            run.add ch
          else:
            if run.len >= MinTextRun:
              let t = run.strip()
              if t notin seen and t.len >= MinTextRun:
                seen.add t
                result.add t
            run = ""
        if run.len >= MinTextRun:
          let t = run.strip()
          if t notin seen and t.len >= MinTextRun:
            seen.add t
            result.add t

proc findDialogueLines(snes: SnesBus): tuple[bg: int, mapBase: int, lines: seq[string], usedBase: int] =
  ## Find the BG most likely holding the dialogue window by scanning enabled layers
  ## for runs that decode to readable text using candidate font bases. Prefer bottom rows.
  ## Returns the winning (bg, its map base from SC, the lines, the font base that worked).
  let enabledMask = snes.ppuRegs[0x2C] or snes.ppuRegs[0x2D]
  var bestScore = 0
  var bestBg = -1
  var bestBase = 0
  var bestLines: seq[string] = @[]
  var bestMap = 0
  for bg in 0..3:
    if ((enabledMask and (1'u8 shl bg)) == 0'u8): continue
    let scReg = snes.ppuRegs[0x07 + bg].int
    let mapBase = ((scReg shr 2) shl 10) and 0x7FFF
    for fb in FontTileBases:
      let cands = decodeWindowText(snes, bg, fb)
      if cands.len == 0: continue
      var score = 0
      for ln in cands:
        var letters = 0
        for c in ln:
          if c in {'A'..'Z', 'a'..'z'}: inc letters
        if letters >= 2: inc score, letters
      var winScore = 0
      let sc2 = snes.ppuRegs[0x07 + bg].int
      let mb2 = ((sc2 shr 2) shl 10) and 0x7FFF
      for row in DialogueRows:
        for col in 0..<32:
          let wi = (mb2 + row*32 + col) and 0x7FFF
          if wi < snes.vram.len:
            let tile = (snes.vram[wi] and 0x03FF).int
            let ch = glyphToChar(tile, fb)
            if ch in {'A'..'Z', 'a'..'z', '0'..'9'}: inc winScore
      let total = score + winScore
      if total > bestScore and cands.len > 0:
        bestScore = total
        bestBg = bg
        bestBase = fb
        bestLines = cands
        bestMap = mapBase
  return (bestBg, bestMap, bestLines, bestBase)

proc getScreenText*(snes: SnesBus): string =
  ## Decode the live on-screen text (BG nametables) to a readable multi-line string.
  ## Returns the dialogue-area rows (in visual order) joined by \n when possible;
  ## falls back to collected runs. Uses same BG+fontBase heuristic as the read_text tool.
  ## READ-ONLY: touches only snes.vram + ppuRegs. Safe for Lua sandbox.
  ## Empty if no plausible text runs (no dialogue/menu visible).
  let (textBg, _, lines, fontBase) = findDialogueLines(snes)
  if textBg >= 0:
    # Always try to emit the visual window rows for the winning layer+base first (screen order)
    let sc2 = snes.ppuRegs[0x07 + textBg].int
    let mb2 = ((sc2 shr 2) shl 10) and 0x7FFF
    var outLines: seq[string] = @[]
    for row in DialogueRows:
      var rowStr = ""
      for col in 0..<32:
        let wi = (mb2 + row*32 + col) and 0x7FFF
        if wi < snes.vram.len:
          let tile = (snes.vram[wi] and 0x03FF).int
          let ch = glyphToChar(tile, fontBase)
          rowStr.add(if ch != '\0': ch else: ' ')
      let t = rowStr.strip()
      if t.len >= MinTextRun:
        outLines.add(t)
    if outLines.len > 0:
      return outLines.join("\n")
    if lines.len > 0:
      return lines.join("\n")
  # Fallback across BGs using runs
  for bg in 0..3:
    let c = decodeWindowText(snes, bg, 0x100)
    if c.len > 0:
      return c.join("\n")
  return ""

type
  PolicyContext* = ref object
    ## Per-run context passed to Lua callbacks via registry lightuserdata.
    snes*: SnesBus
    frameImage*: Image
    frameCount*: int
    joy1*: uint16
    targetFps*: int = 0
      ## 0 = unlimited (run as fast as possible). >0 = target frames/sec for emulation pacing.
      ## Read by llm_ai main loop each frame; written by sim.setSpeed from inside policy update().

proc countHook*(L: lua53.PState, ar: pointer) {.cdecl.} =
  ## Debug hook installed around each update() call. Errors out of the pcall
  ## if the policy runs too many instructions (sandbox CPU bound).
  L.pushstring("policy update interrupted by debug hook after instruction limit".cstring)
  discard L.error()

proc getPolicyCtx*(L: lua53.PState): PolicyContext {.inline.} =
  ## Retrieve the PolicyContext stored in the Lua registry by setup.
  L.getfield(lua53.RegistryIndex.cint, CtxRegKey.cstring)
  let p = L.touserdata(-1)
  L.pop(1)
  cast[PolicyContext](p)

proc memRead*(L: lua53.PState): cint {.cdecl.} =
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

proc isSystemBank(bank: int): bool {.inline.} =
  ## True for banks that host low-RAM mirrors + the $2000-$5FFF port window.
  (bank <= SystemBankMax) or (bank >= SystemBankHiMin and bank <= SystemBankHiMax)

proc snesPeekByte*(snes: SnesBus, address: int): int =
  ## Side-effect-free byte peek of the 24-bit SNES address space.
  ## Resolves WRAM (and low-RAM mirrors) and ROM mirrors the same way the bus
  ## maps them, but never calls bus.read8 / mmioRead (hardware ports latch).
  ## MMIO window ($2000-$5FFF in system banks) and cart SRAM return 0.
  let a = address and SnesAddrMask
  let bank = a shr 16
  let offset = a and 0xFFFF
  if isSystemBank(bank):
    if offset < LowRamSize:
      return snes.bus.mem[WramMirrorBase or offset].int
    if offset >= MmioWindowLo and offset <= MmioWindowHi:
      return 0
    if offset >= SramWindowLo and offset <= SramWindowHi and
        (bank and SystemBankMax) >= SramBankMin:
      return 0
  if a < 0 or a >= snes.bus.mem.len:
    return 0
  return snes.bus.mem[a].int

proc snesRead*(L: lua53.PState): cint {.cdecl.} =
  ## Lua binding: snes.read(addr) -> int.
  ## Full-bus read-only peek; MMIO/APU/PPU ports and SRAM return 0 (no side effects).
  let ctx = getPolicyCtx(L)
  let a = L.toInteger(1).int
  L.pushinteger(snesPeekByte(ctx.snes, a))
  return 1

proc snesReadRange*(L: lua53.PState): cint {.cdecl.} =
  ## Lua binding: snes.readRange(addr, len) -> 1-based table of ints.
  ## Same address rules as snes.read. len is clamped to [0, SnesReadRangeMax].
  let ctx = getPolicyCtx(L)
  let a = L.toInteger(1).int
  var n = L.toInteger(2).int
  if n < 0:
    n = 0
  if n > SnesReadRangeMax:
    n = SnesReadRangeMax
  L.createtable(n.cint, 0)
  for i in 0 ..< n:
    L.pushinteger(snesPeekByte(ctx.snes, a + i))
    L.luaSeti(-2, lua53.Integer(i + 1))
  return 1

proc screenPixel*(L: lua53.PState): cint {.cdecl.} =
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

proc screenText*(L: lua53.PState): cint {.cdecl.} =
  ## Lua binding: screen.text() -> string.
  ## Returns the current on-screen decoded text (from BG tilemap scan + EB glyph reverse).
  ## Multi-line (lines separated by \n). Lets policies read menus/dialogue/battle commands
  ## ("INPUT YOUR COMMAND.", "Bash", "PSI", etc) instead of blind input.
  ## READ-ONLY + safe (no host FS/ROM access; same boundary as screen.pixel/mem.read).
  let ctx = getPolicyCtx(L)
  let txt = getScreenText(ctx.snes)
  L.pushstring(txt.cstring)
  return 1

proc padSet*(L: lua53.PState): cint {.cdecl.} =
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

proc padPress*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: pad.press("A") is shorthand for set true (for this next frame).
  let ctx = getPolicyCtx(L)
  let btn = L.toString(1)
  ctx.joy1 = ctx.joy1 or nameToMask(btn)
  return 0

proc frameGetter*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: frame() -> current frame count (starts at 0 before first step).
  let ctx = getPolicyCtx(L)
  L.pushinteger(ctx.frameCount)
  return 1

proc simSetSpeed*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: sim.setSpeed(fps). Agent-controlled emulation speed (unsyncs from real-time).
  ## 0=unlimited (fast-forward safe stretches), 60=normal, higher for speed. Clamped sane.
  ## Value is read each frame by llm_ai pacing; survives across LLM policy reloads until changed.
  let ctx = getPolicyCtx(L)
  var fps = L.toInteger(1).int
  if fps < 0: fps = 0
  if fps > 360: fps = 360
  ctx.targetFps = fps
  return 0

proc simFast*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: sim.fast(). Convenience: set high fps (e.g. 300) for fast progress through low-risk areas.
  let ctx = getPolicyCtx(L)
  ctx.targetFps = 300
  return 0

proc simNormal*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: sim.normal(). Convenience: set 60 fps for reaction-sensitive moments (menus, fights, text).
  let ctx = getPolicyCtx(L)
  ctx.targetFps = 60
  return 0

proc setupPolicyApi*(L: lua53.PState, ctx: PolicyContext) =
  ## Expose the read-only + input-only sandboxed surface to Lua.
  ## mem.read (WRAM-only, unchanged), snes.read / snes.readRange (full-bus, side-effect-free),
  ## screen.{width,height,pixel,text}, pad.{set,press}, frame, sim.{setSpeed,fast,normal}.
  ## screen.text() returns decoded BG tilemap on-screen text (menus, dialogue, battle commands).
  ## snes.* peeks ROM/WRAM mirrors without touching MMIO (ports return 0). Writes stay pad-only.
  ## sim.* controls targetFps in ctx (read by llm_ai loop; additive only, llm_play unaffected).
  # Store ctx in Lua registry under string key so callbacks can retrieve without upvalues.
  L.pushlightuserdata(cast[pointer](ctx))
  L.setfield(lua53.RegistryIndex.cint, CtxRegKey.cstring)
  # mem
  L.newtable()
  L.pushcfunction(memRead)
  L.setfield(-2, "read".cstring)
  L.setglobal("mem".cstring)
  # snes (full-bus read-only; prerequisite for Lua map/collision navigation)
  L.newtable()
  L.pushcfunction(snesRead)
  L.setfield(-2, "read".cstring)
  L.pushcfunction(snesReadRange)
  L.setfield(-2, "readRange".cstring)
  L.setglobal("snes".cstring)
  # screen
  L.newtable()
  L.pushinteger(ppu.ScreenWidth)
  L.setfield(-2, "width".cstring)
  L.pushinteger(ppu.ScreenHeight)
  L.setfield(-2, "height".cstring)
  L.pushcfunction(screenPixel)
  L.setfield(-2, "pixel".cstring)
  L.pushcfunction(screenText)
  L.setfield(-2, "text".cstring)
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
  # sim (fps control exposed to policy so agent can drive emulation rate independent of LLM tick)
  L.newtable()
  L.pushcfunction(simSetSpeed)
  L.setfield(-2, "setSpeed".cstring)
  L.pushcfunction(simFast)
  L.setfield(-2, "fast".cstring)
  L.pushcfunction(simNormal)
  L.setfield(-2, "normal".cstring)
  L.setglobal("sim".cstring)

proc stepOneFrame*(snes: SnesBus, cpu: var Cpu, image: Image) =
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

proc runPolicyFrame*(L: lua53.PState, ctx: PolicyContext): string =
  ## Execute one tick of the policy: reset joy1, invoke global update() under
  ## the instruction limit hook, return "" on success or the error message.
  ## The caller applies ctx.joy1 to snes.joy1 after this (even on error path).
  ctx.joy1 = 0'u16
  L.sethook(countHook, lua53.MASKCOUNT, 20000.cint)
  L.getglobal("update".cstring)
  if L.getType(-1) != lua53.TFUNCTION:
    L.pop(1)
    L.sethook(cast[lua53.Hook](nil), 0.cint, 0.cint)
    return "no update() function exported by policy"
  let callStatus = L.pcall(0, 0, 0)
  L.sethook(cast[lua53.Hook](nil), 0.cint, 0.cint)
  if callStatus != lua53.OK:
    let msg = L.toString(-1)
    L.pop(1)
    return msg
  return ""
