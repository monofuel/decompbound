## Shared harness primitives for sandboxed Lua policy runners (milestones 2b/2c).
## Joypad masks, PolicyContext, the exact mem/screen/pad/frame bindings,
## setup, update caller, and deterministic one-frame stepper.
## Both llm_play.nim and llm_ai.nim use this so the Lua->joy1 path is identical.
## The harness + API is our code; ROM and any dumps are user-supplied at runtime.

import
  std/[strutils, math],
  pixie,
  ./[cpu, ppu, snesbus, lua53]

const
  InstrPerLine* = 150  # match play.nim's frame budget; at 40 the game is CPU-starved
                       # and never boots past force-blank (black frames in llm_ai/play).

  # A* re-plan over a 64×64 collision page needs headroom; still bounded against runaway policies.
  PolicyInstrBudget* = 200_000

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

  # Collision / nav (disasm $C05F33 file 0x005F33; walk gate file 0x0029CC AND #$00D0).
  # Page at WRAM $7EE000 (DBR=$7E → absolute $E000). Index formula file 0x00565A..0x005670.
  NavCollWram = 0x7EE000
  NavBlockMask = 0x00D0
  # Hitbox tables HiROM $C4 (file 0x042A1F..). Indexed by entity type * 2.
  NavTblXOff = 0xC42A1F
  NavTblYOff = 0xC42A41
  NavTblYExt = 0xC42AEB
  NavTblWCnt = 0xC42AA7
  NavTblHCnt = 0xC42AC9
  # Entity hitbox type array $2B6E,X; player slot 24 → index 0x30 (type 5 outdoor).
  NavHitboxTypeBase = 0x2B6E
  NavPlayerSlotIdx = 0x30
  # Player world pos: WorldXBase 0x0B8E + 0x30, WorldYBase 0x0BCA + 0x30.
  NavPlayerXOff = 0x0BBE
  NavPlayerYOff = 0x0BFA
  # Page wraps mod 64 tiles (512×512 px); plan only within this pixel radius of
  # the start so wrapped rows never alias. Planning is PIXEL-space (1px BFS):
  # tile-center sampling forbids the narrow 01/03 corridors the game threads at
  # specific alignments (the old "stuck-wiggle" corridors, e.g. Onett crest).
  NavPlanRadiusPx = 192
  NavWinSide = NavPlanRadiusPx * 2 + 1
  NavWinCells = NavWinSide * NavWinSide
  # Emit a waypoint at every direction change or this many px along a straight run.
  NavWaypointStride = 8
  # Goal counts as reached within this manhattan distance of the target pixel.
  NavGoalSlack = 6

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

proc snesPeekU16Le(snes: SnesBus, address: int): int {.inline.} =
  ## Little-endian u16 via side-effect-free peek.
  snesPeekByte(snes, address) or (snesPeekByte(snes, address + 1) shl 8)

proc navCollByte(snes: SnesBus, cx, cy: int): int =
  ## One collision page byte: WRAM $7EE000 + ((cy&0x3F)<<6)|(cx&0x3F).
  ## Index formula file 0x00565A..0x005670.
  let
    x = cx and 0x3F
    y = cy and 0x3F
    idx = (y shl 6) or x
  snesPeekByte(snes, NavCollWram + idx)

proc navHitboxParams(snes: SnesBus): tuple[xOff, yOff, yExt, hCnt, wCnt: int] =
  ## Live player hitbox table entries for outdoor/entity type at slot 24.
  let
    typ = snesPeekU16Le(snes, WramMirrorBase or (NavHitboxTypeBase + NavPlayerSlotIdx))
    t2 = typ * 2
  result.xOff = snesPeekU16Le(snes, NavTblXOff + t2)
  result.yOff = snesPeekU16Le(snes, NavTblYOff + t2)
  result.yExt = snesPeekU16Le(snes, NavTblYExt + t2)
  result.hCnt = snesPeekU16Le(snes, NavTblHCnt + t2)
  result.wCnt = snesPeekU16Le(snes, NavTblWCnt + t2)
  if result.wCnt < 1:
    result.wCnt = 1
  if result.hCnt < 1:
    result.hCnt = 1

proc navOrFootprint(snes: SnesBus, xAdj, yAdj, hCnt, wCnt: int): int =
  ## OR collision bytes over the hitbox footprint ($C05639 + $C056D0).
  ## Left col from xAdj; right col from xAdj+(wCnt<<3)-1; rows yAdj>>3 and hCnt from (yAdj+7)>>3.
  var acc = 0
  let leftCx = (xAdj shr 3) and 0x3F
  let rightPx = xAdj + (wCnt shl 3) - 1
  let rightCx = (rightPx shr 3) and 0x3F
  let firstCy = (yAdj shr 3) and 0x3F
  acc = acc or navCollByte(snes, leftCx, firstCy)
  acc = acc or navCollByte(snes, rightCx, firstCy)
  var row = (yAdj + 7) shr 3
  var i = 0
  while i < hCnt:
    let cy = row and 0x3F
    acc = acc or navCollByte(snes, leftCx, cy)
    acc = acc or navCollByte(snes, rightCx, cy)
    inc row
    inc i
  acc

proc navWalkableHp(snes: SnesBus,
    hp: tuple[xOff, yOff, yExt, hCnt, wCnt: int], px, py: int): bool {.inline.} =
  ## navWalkablePx with hitbox params hoisted (BFS inner loop).
  let xAdj = px - hp.xOff
  let yAdj = py - hp.yOff + hp.yExt
  let flags = navOrFootprint(snes, xAdj, yAdj, hp.hCnt, hp.wCnt)
  (flags and NavBlockMask) == 0

proc navWalkablePx*(snes: SnesBus, px, py: int): bool =
  ## Full-hitbox walkability at world pixel (px, py). True iff ($C05F33 flags & 0xD0) == 0.
  ## Exact port of probe_walkable: type from $2B6E+slot*2; xAdj/yAdj from ROM tables;
  ## blocked gate file 0x0029CC AND #$00D0.
  navWalkableHp(snes, navHitboxParams(snes), px, py)

proc navWinIndex(x, y, minX, minY: int): int {.inline.} =
  ## Flat index into the ±NavPlanRadiusPx pixel planning window.
  (y - minY) * NavWinSide + (x - minX)

proc navFindPath*(snes: SnesBus, sx, sy, tx, ty: int): seq[(int, int)] =
  ## Pixel-space BFS (1px steps, 4-neighbor) within ±NavPlanRadiusPx of (sx,sy).
  ## A pixel is enterable iff navWalkablePx — the EXACT game gate ($C05F33 flags
  ## & 0xD0, full hitbox), so narrow 01/03 corridors that only pass at specific
  ## alignments are found without wiggle heuristics. Goal = any pixel within
  ## NavGoalSlack manhattan of (tx,ty) when in-window; else the reachable pixel
  ## minimizing euclidean distance to the target (frontier steering).
  ## Returns world-pixel waypoints at direction changes / every NavWaypointStride
  ## px (skips the start). Empty = no path.
  result = @[]
  let hp = navHitboxParams(snes)
  let minX = sx - NavPlanRadiusPx
  let maxX = sx + NavPlanRadiusPx
  let minY = sy - NavPlanRadiusPx
  let maxY = sy + NavPlanRadiusPx
  let targetInWindow = tx >= minX and tx <= maxX and ty >= minY and ty <= maxY

  var visited = newSeq[bool](NavWinCells)
  var parent = newSeq[int32](NavWinCells)
  for i in 0 ..< NavWinCells:
    parent[i] = -1

  var q = newSeqOfCap[(int, int)](NavWinCells div 4)
  q.add (sx, sy)
  visited[navWinIndex(sx, sy, minX, minY)] = true
  var head = 0
  var foundGoal = false
  var goalX = sx
  var goalY = sy
  const Dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]

  while head < q.len:
    let (x, y) = q[head]
    inc head
    if targetInWindow and abs(x - tx) + abs(y - ty) <= NavGoalSlack:
      foundGoal = true
      goalX = x
      goalY = y
      break
    for (dx, dy) in Dirs:
      let nx = x + dx
      let ny = y + dy
      if nx < minX or nx > maxX or ny < minY or ny > maxY:
        continue
      let ni = navWinIndex(nx, ny, minX, minY)
      if visited[ni]:
        continue
      visited[ni] = true
      # Start is enterable by definition; every other pixel needs the gate clear.
      if not navWalkableHp(snes, hp, nx, ny):
        continue
      parent[ni] = int32(navWinIndex(x, y, minX, minY))
      q.add (nx, ny)

  if targetInWindow:
    if not foundGoal:
      return @[]
  else:
    # Frontier steering: among reached pixels, minimize euclidean to the target.
    var bestD = high(float)
    var any = false
    for i in 0 ..< q.len:
      let (x, y) = q[i]
      if x == sx and y == sy:
        continue
      let d = hypot(float(x - tx), float(y - ty))
      if d < bestD:
        bestD = d
        goalX = x
        goalY = y
        any = true
    if not any:
      return @[]

  # Reconstruct pixel path start → goal.
  var pixels: seq[(int, int)] = @[]
  var ci = navWinIndex(goalX, goalY, minX, minY)
  while ci >= 0:
    pixels.add (minX + (ci mod NavWinSide), minY + (ci div NavWinSide))
    ci = parent[ci]
  var i = 0
  var j = pixels.len - 1
  while i < j:
    swap(pixels[i], pixels[j])
    inc i
    dec j
  if pixels.len <= 1:
    return @[]

  # Compress to waypoints: direction changes + every NavWaypointStride px.
  var run = 0
  for k in 1 ..< pixels.len:
    let last = k == pixels.len - 1
    var turn = false
    if k + 1 < pixels.len:
      let dx0 = pixels[k][0] - pixels[k-1][0]
      let dy0 = pixels[k][1] - pixels[k-1][1]
      let dx1 = pixels[k+1][0] - pixels[k][0]
      let dy1 = pixels[k+1][1] - pixels[k][1]
      turn = dx0 != dx1 or dy0 != dy1
    inc run
    if last or turn or run >= NavWaypointStride:
      result.add pixels[k]
      run = 0

proc navWalkableLua*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: nav.walkable(px, py) -> bool. Full-hitbox walkability at world pixels.
  let ctx = getPolicyCtx(L)
  let px = L.toInteger(1).int
  let py = L.toInteger(2).int
  L.pushboolean(if navWalkablePx(ctx.snes, px, py): 1 else: 0)
  return 1

proc navFindPathLua*(L: lua53.PState): cint {.cdecl.} =
  ## Lua: nav.findPath(tx, ty) -> 1-based table of {x=, y=} world-pixel waypoints.
  ## Start is live player slot-24 pos; empty table means no path this plan window.
  let ctx = getPolicyCtx(L)
  let tx = L.toInteger(1).int
  let ty = L.toInteger(2).int
  let sx = snesPeekU16Le(ctx.snes, WramMirrorBase or NavPlayerXOff)
  let sy = snesPeekU16Le(ctx.snes, WramMirrorBase or NavPlayerYOff)
  let path = navFindPath(ctx.snes, sx, sy, tx, ty)
  L.createtable(path.len.cint, 0)
  for i, wp in path:
    L.newtable()
    L.pushinteger(lua53.Integer(wp[0]))
    L.setfield(-2, "x".cstring)
    L.pushinteger(lua53.Integer(wp[1]))
    L.setfield(-2, "y".cstring)
    L.luaSeti(-2, lua53.Integer(i + 1))
  return 1

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
  ## nav.walkable / nav.findPath (native hitbox collision + BFS pathfinding),
  ## screen.{width,height,pixel,text}, pad.{set,press}, frame, sim.{setSpeed,fast,normal}.
  ## screen.text() returns decoded BG tilemap on-screen text (menus, dialogue, battle commands).
  ## snes.* peeks ROM/WRAM mirrors without touching MMIO (ports return 0). Writes stay pad-only.
  ## nav.* plans over WRAM $7EE000 via $C05F33 (file 0x005F33 / gate 0x0029CC); findPath starts
  ## from live player slot-24 pos. sim.* controls targetFps in ctx (llm_ai loop; llm_play unaffected).
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
  # nav (native pathfinding; Lua only follows waypoints)
  L.newtable()
  L.pushcfunction(navWalkableLua)
  L.setfield(-2, "walkable".cstring)
  L.pushcfunction(navFindPathLua)
  L.setfield(-2, "findPath".cstring)
  L.setglobal("nav".cstring)
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
  L.sethook(countHook, lua53.MASKCOUNT, PolicyInstrBudget.cint)
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
