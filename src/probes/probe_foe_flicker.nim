## Dynamic trace: FOE-line flicker mid-battle.
##
## Loads bin/states/slot200.state (Starman Super + Atomic Power Robot) and
## A-mashes through text/actions while chain-wrapping writeHook on:
##   - $7E:A970..A99F  (enemy battler pointer list)
##   - battler id words (+0 at each load-time enemy ptr, and fixed $A21C / $A26A)
## Logs writer PCs + values when they change; samples formation + nearby
## battler offsets for a stable id field; watches $5D60 for battle-end.
##
## Usage: nim r --hints:off src/probes/probe_foe_flicker.nim [rom] [state]
## Writes /tmp/foe_flicker_trace.md and appends findings to /tmp/foe_flicker_summary.md.

import
  std/[algorithm, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy, battle_formation]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/slot200.state"
  TracePath = "/tmp/foe_flicker_trace.md"
  SummaryPath = "/tmp/foe_flicker_summary.md"
  PtrTableBase = 0xA970
  PtrTableEnd = 0xA99F
  FixedIdA = 0xA21C
  FixedIdB = 0xA26A
  Code5D60 = 0x5D60
  AmashWidth = 3
  AmashPeriod = 12
  MaxFrames = 900
  SampleEvery = 1

type
  WriteHit = object
    frame: int
    pc: uint32
    waddr: int
    value: uint8
    prev: uint8
    kind: string

  FormSnap = object
    frame: int
    line: string
    ids: seq[int]
    hps: seq[int]
    ptrs: seq[int]
    code5d60: int
    inBattle: bool
    mode: int
    fixedA: int
    fixedB: int
    battlerBytes: seq[string]  ## hex dump +0..+0x2F per enemy ptr

  TraceObj = object
    frame: int
    writes: seq[WriteHit]
    samples: seq[FormSnap]
    idChangeFrames: seq[int]
  Trace = ref TraceObj

proc wramOff(address: uint32): int =
  ## Map bus address to WRAM 16-bit offset, or -1.
  let bank = address shr 16
  let off = address and 0xFFFF
  if bank == 0x7E or bank == 0x7F:
    return off.int
  if (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
    return off.int
  -1

proc wram8(snes: SnesBus, off: int): uint8 =
  ## Byte at WRAM $7E:off.
  snes.bus.mem[0x7E0000 + (off and 0x1FFFF)]

proc wram16(snes: SnesBus, off: int): int =
  ## LE WRAM word.
  wram8(snes, off).int or (wram8(snes, off + 1).int shl 8)

proc enemyPtrs(snes: SnesBus): seq[int] =
  ## Snapshot $A970 enemy battler pointers.
  result = @[]
  for i in 0 ..< 6:
    let p = wram16(snes, PtrTableBase + i * 2)
    if p == 0 or p == 0xFFFF:
      break
    if p < 0x2000 or p > 0x1F000:
      break
    result.add p

proc dumpBattler(snes: SnesBus, p: int): string =
  ## Hex dump battler +0..+0x2F (id, flags, HP region, nearby).
  var parts: seq[string]
  for off in 0 .. 0x2F:
    parts.add &"{wram8(snes, p + off):02X}"
  &"${p:04X}: " & parts.join(" ")

proc takeSnap(snes: SnesBus, frame: int): FormSnap =
  ## Capture formation + fixed ids + battler dumps + battle-end signal.
  let form = readBattleFormation(snes)
  result.frame = frame
  result.line = formationLine(form)
  result.ids = @[]
  result.hps = @[]
  result.ptrs = enemyPtrs(snes)
  for e in form.enemies:
    result.ids.add e.id
    result.hps.add e.hp
  result.code5d60 = wram16(snes, Code5D60)
  result.inBattle = policy.isInBattle(snes)
  result.mode = snes.ppuRegs[0x05].int and 7
  result.fixedA = wram16(snes, FixedIdA)
  result.fixedB = wram16(snes, FixedIdB)
  result.battlerBytes = @[]
  for p in result.ptrs:
    result.battlerBytes.add dumpBattler(snes, p)

proc installHooks(snes: SnesBus, c: var Cpu, tr: Trace, watchIds: seq[int]) =
  ## Chain writeHook on $A970-$A99F and battler id words (+0,+1).
  let prev = snes.bus.writeHook
  let cpuPtr = addr c
  var idSet: seq[int] = @[]
  for p in watchIds:
    idSet.add p
    idSet.add p + 1
  # Also fixed candidates named in the ticket.
  idSet.add FixedIdA
  idSet.add FixedIdA + 1
  idSet.add FixedIdB
  idSet.add FixedIdB + 1
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let woff = wramOff(address)
    if woff < 0:
      if prev != nil:
        return prev(address, value)
      return false
    var kind = ""
    if woff >= PtrTableBase and woff <= PtrTableEnd:
      kind = "ptr"
    elif woff in idSet:
      kind = "id"
    if kind.len > 0:
      let pc = (cpuPtr[].pbr.uint32 shl 16) or cpuPtr[].pc.uint32
      let prevVal = snes.bus.mem[0x7E0000 + woff]
      if prevVal != value or tr.writes.len < 4:
        if tr.writes.len < 20000:
          tr.writes.add WriteHit(
            frame: tr.frame, pc: pc, waddr: woff, value: value,
            prev: prevVal, kind: kind)
    if prev != nil:
      return prev(address, value)
    false

proc stepFrame(snes: SnesBus, c: var Cpu, img: Image) =
  ## One policy-style frame (no RNG watch — writeHook does the work).
  var line = 0
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (c.stopped or c.waiting):
        c.step(snes.bus)
      if c.stopped:
        break
    if line < 224:
      snes.runHdma()
    for k in 0 ..< 2:
      discard snes.tickApu()
    inc line
    if line >= 262:
      snes.initHdma()
      break

proc countWriterPcs(writes: seq[WriteHit], kind: string): seq[(uint32, int)] =
  ## Top writer PCs for a kind, sorted by count desc.
  var ct: CountTable[uint32]
  for w in writes:
    if w.kind == kind:
      ct.inc(w.pc)
  result = @[]
  for k, v in ct:
    result.add (k, v)
  result.sort(proc(a, b: (uint32, int)): int = cmp(b[1], a[1]))

proc main() =
  ## Drive slot200 A-mash and emit flicker trace.
  let romPath = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  if not fileExists(romPath):
    raise newException(IOError, "ROM not found: " & romPath)
  if not fileExists(statePath):
    raise newException(IOError, "state not found: " & statePath)

  let rom = policy.readRomFile(romPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)

  let eptrs0 = enemyPtrs(snes)
  let form0 = readBattleFormation(snes)
  echo &"load: form=[{formationLine(form0)}] ptrs={eptrs0} " &
    &"inB={policy.isInBattle(snes)} 5D60=${wram16(snes, Code5D60):04X} " &
    &"A21C=${wram16(snes, FixedIdA):04X} A26A=${wram16(snes, FixedIdB):04X}"

  # Also dump raw id at each ptr + nearby words for stable-id hunt.
  for p in eptrs0:
    echo &"  battler ${p:04X} +0 id={wram16(snes, p)} HP@+11={wram16(snes, p + 0x11)}"
    var words: seq[string]
    for w in 0 .. 15:
      words.add &"+{w*2:02X}={wram16(snes, p + w*2):04X}"
    echo "    " & words.join(" ")

  let tr = Trace(frame: 0, writes: @[], samples: @[], idChangeFrames: @[])
  installHooks(snes, c, tr, eptrs0)

  var prevIds: seq[int] = @[]
  for e in form0.enemies:
    prevIds.add e.id
  tr.samples.add takeSnap(snes, 0)

  var bothDeadAt = -1
  var listZeroAt = -1
  var code78At = -1
  var leftBattleAt = -1
  var flickerCount = 0
  var badIdFrames = 0

  for f in 0 ..< MaxFrames:
    tr.frame = f
    snes.joy1 = if (f mod AmashPeriod) < AmashWidth: policy.BtnA else: 0
    stepFrame(snes, c, img)
    if c.stopped:
      echo &"CPU stopped at f={f}"
      break

    let form = readBattleFormation(snes)
    var ids: seq[int] = @[]
    for e in form.enemies:
      ids.add e.id
    let code = wram16(snes, Code5D60)
    let inB = policy.isInBattle(snes)
    let ptrs = enemyPtrs(snes)

    if ids != prevIds:
      tr.idChangeFrames.add f
      let snap = takeSnap(snes, f)
      tr.samples.add snap
      echo &"f={f} ID-CHANGE was={prevIds} now={ids} line=[{snap.line}] " &
        &"5D60=${code:04X} inB={inB} ptrs={ptrs}"
      prevIds = ids
      # Count bad ids (not 13 or 68 while battle expected).
      for id in ids:
        if id notin [13, 68]:
          inc badIdFrames
          inc flickerCount

    if f mod 60 == 0 or f == MaxFrames - 1:
      let snap = takeSnap(snes, f)
      if tr.samples.len == 0 or tr.samples[^1].frame != f:
        tr.samples.add snap
      echo &"f={f} form=[{snap.line}] 5D60=${code:04X} inB={inB} " &
        &"A21C=${snap.fixedA:04X} A26A=${snap.fixedB:04X} mode={snap.mode}"

    if bothDeadAt < 0:
      var allDead = eptrs0.len > 0
      for p in eptrs0:
        if wram16(snes, p + 0x11) != 0:
          allDead = false
          break
      if allDead:
        bothDeadAt = f
        echo &"f={f} BOTH DEAD (HP@+11==0 on load-time ptrs)"

    if listZeroAt < 0 and ptrs.len == 0:
      listZeroAt = f
      echo &"f={f} $A970 list emptied"

    if code78At < 0 and code == 0x78:
      code78At = f
      echo &"f={f} $5D60 == $0078 (victory code)"

    if leftBattleAt < 0 and not inB and f > 30:
      leftBattleAt = f
      echo &"f={f} isInBattle false (left battle)"

  # ---- report ----
  var lines: seq[string]
  lines.add "# FOE flicker dynamic trace"
  lines.add ""
  lines.add &"State: `{statePath}`  frames={MaxFrames}  A-mash {AmashWidth}/{AmashPeriod}"
  lines.add &"Load formation: `{formationLine(form0)}`  ptrs={eptrs0}"
  lines.add &"ID-change events: {tr.idChangeFrames.len}  bad-id frames (sample): {badIdFrames}"
  lines.add &"bothDeadAt={bothDeadAt}  listZeroAt={listZeroAt}  code78At={code78At}  leftBattleAt={leftBattleAt}"
  lines.add &"Total writes logged: {tr.writes.len}"
  lines.add ""

  lines.add "## Writer PCs — $A970-$A99F (ptr table)"
  lines.add ""
  for (pc, n) in countWriterPcs(tr.writes, "ptr"):
    lines.add &"- `${pc:06X}` ×{n}"
  if countWriterPcs(tr.writes, "ptr").len == 0:
    lines.add "- (none)"
  lines.add ""

  lines.add "## Writer PCs — battler id words (+0 and fixed $A21C/$A26A)"
  lines.add ""
  for (pc, n) in countWriterPcs(tr.writes, "id"):
    lines.add &"- `${pc:06X}` ×{n}"
  if countWriterPcs(tr.writes, "id").len == 0:
    lines.add "- (none)"
  lines.add ""

  lines.add "## Sample write log (first 80 + around id-changes)"
  lines.add ""
  let showN = min(80, tr.writes.len)
  for i in 0 ..< showN:
    let w = tr.writes[i]
    lines.add &"- f={w.frame} {w.kind} ${w.waddr:04X} {w.prev:02X}->{w.value:02X} pc=${w.pc:06X}"
  lines.add ""

  lines.add "## ID-change samples (formation re-decode)"
  lines.add ""
  for s in tr.samples:
    if s.frame == 0 or s.frame in tr.idChangeFrames or s.frame mod 120 == 0:
      lines.add &"- f={s.frame} ids={s.ids} hps={s.hps} line=`{s.line}` " &
        &"5D60=${s.code5d60:04X} inB={s.inBattle} A21C=${s.fixedA:04X} A26A=${s.fixedB:04X}"
      for d in s.battlerBytes:
        lines.add &"    {d}"
  lines.add ""

  # Stable-field hunt: for each load-time battler, find offsets whose u16
  # never left the load value across all samples that still have that ptr.
  lines.add "## Stable u16 fields on load-time battlers (across samples)"
  lines.add ""
  for pi, p in eptrs0:
    var stable: seq[int] = @[]
    for off in 0 .. 0x2E:
      if off mod 2 != 0: continue
      let v0 = wram16(snes, p + off)  # end-state — use first sample instead
      discard v0
    # Use first sample dump if available.
    if tr.samples.len == 0:
      continue
    # Re-read from first sample is hard (we only stored hex). Re-walk by
    # re-deserializing is overkill; instead compare id at +0 across change events.
    let id0 = form0.enemies[pi].id
    lines.add &"- battler ${p:04X} load id={id0}"
  lines.add ""
  lines.add "See console battler word dump at load; re-run with per-frame" &
    " stability if needed."
  lines.add ""

  writeFile(TracePath, lines.join("\n"))
  echo "wrote ", TracePath

  # Compact summary for the ticket.
  var sum: seq[string]
  sum.add "# FOE flicker — incremental summary"
  sum.add ""
  sum.add "## 1. Dynamic trace (probe_foe_flicker)"
  sum.add ""
  sum.add &"- State: `{statePath}` A-mash {MaxFrames}f"
  sum.add &"- Load: `{formationLine(form0)}` ptrs={eptrs0}"
  sum.add &"- ID-change events while re-decoding: **{tr.idChangeFrames.len}**"
  sum.add &"- bad-id (not 13/68) samples: **{badIdFrames}**"
  sum.add &"- bothDeadAt={bothDeadAt} listZeroAt={listZeroAt} " &
    &"code78At={code78At} leftBattleAt={leftBattleAt}"
  sum.add ""
  sum.add "### Writer PCs (ptr table $A970-$A99F)"
  for (pc, n) in countWriterPcs(tr.writes, "ptr"):
    sum.add &"- `${pc:06X}` ×{n}"
  if countWriterPcs(tr.writes, "ptr").len == 0:
    sum.add "- (none during A-mash window)"
  sum.add ""
  sum.add "### Writer PCs (id words)"
  for (pc, n) in countWriterPcs(tr.writes, "id"):
    sum.add &"- `${pc:06X}` ×{n}"
  if countWriterPcs(tr.writes, "id").len == 0:
    sum.add "- (none during A-mash window)"
  sum.add ""
  sum.add "### Full write log + dumps: `/tmp/foe_flicker_trace.md`"
  sum.add ""
  writeFile(SummaryPath, sum.join("\n"))
  echo "wrote ", SummaryPath
  echo "OK probe_foe_flicker done"

when isMainModule:
  main()
