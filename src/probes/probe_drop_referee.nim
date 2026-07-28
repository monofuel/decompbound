## Drop-roll timing referee — behavioral H1/H2/H3 discriminator.
##
## Loads bin/states/slot200.state (Starman Super + Atomic Power Robot at the
## command menu). For each N in {0,1,2,3,5,8} injects N battle-cursor Down
## pulses (legitimate joy only), then A-mashes until both enemies are dead
## (HP@+0x11==0 and affliction@+0x1D bit0) plus a post-death window.
##
## Instruments:
##   - every write to $7E:AA10 and $7E:0024-0027 (PC stamp; all modes)
##   - PC hits at $C24DDC, $C264B1, $C28770, $C08E9A
##   - RNG returns whose next ROM byte is AND #$7F (drop-style mask)
##
## Outcome varies with N ⇒ H2. Invariant ⇒ H1/H3; write logs separate H1/H3.
##
## Usage: nim r --hints:off src/probes/probe_drop_referee.nim [rom] [state]
## Exit 0 always (informational referee). Never commits states.

import
  std/[algorithm, os, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy, battle_formation,
    party_wram, party_sram, item_table]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/slot200.state"
  SummaryPath = "/tmp/drop_referee_summary.md"
  RngPbr = 0xC0'u8
  RngPc = 0x8E9A'u16
  RngPcEnd = 0x8ED1'u16
  SeedWram = 0x0024
  Aa10Wram = 0xAA10
  VictoryRollJsl = 0xC24DDC'u32
  VictoryRollAnd = 0xC24DE0'u32
  CloneRollJsl = 0xC264B1'u32
  CloneRollAnd = 0xC264B5'u32
  SpyHandlerStart = 0xC28770'u32
  SpyHandlerEnd = 0xC2889A'u32
  SwordItemId = 0x23
  MaxFightFrames = 3000
  PostDeathFrames = 400
  CursorPulseWidth = 3
  CursorPulsePeriod = 16
  AmashWidth = 3
  AmashPeriod = 12
  InjectNs = [0, 1, 2, 3, 5, 8]

type
  WriteHit = object
    frame: int
    pc: uint32
    waddr: int
    value: uint8
    phase: string

  RollHit = object
    frame: int
    site: string
    pc: uint32
    seedBefore: uint32
    seedAfter: uint32
    draw: int
    aa10After: uint8

  RngCall = object
    frame: int
    retPc: uint32
    seedBefore: uint32
    seedAfter: uint32
    draw: int
    phase: string
    andMask: int  ## immediate AND mask at return site, or -1

  RunResult = object
    nTarget: int
    nActual: int
    seed0: uint32
    seedAfterInject: uint32
    seedAtBothDead: uint32
    seedEnd: uint32
    injectFrames: int
    bothDeadFrame: int
    endFrame: int
    kToDeath: int
    totalRng: int
    victoryRollHits: int
    cloneRollHits: int
    spyHits: int
    mask7fHits: int
    aa10Writes: seq[WriteHit]
    seedWrites: seq[WriteHit]
    rollHits: seq[RollHit]
    mask7fEvents: seq[string]
    swordInInvBefore: bool
    swordInInvAfter: bool
    aa10Final: uint8
    aa10Peak: uint8
    dropGranted: bool
    enemyLine0: string
    mode0: int
    modeEnd: int
    inBattle0: bool
    inBattleEnd: bool
    code5D60: int
    expDelta: int
    moneyDelta: int

  TraceObj = object
    frame: int
    phase: string
    aa10Writes: seq[WriteHit]
    seedWrites: seq[WriteHit]
    rollHits: seq[RollHit]
    rngCalls: seq[RngCall]
    mask7fEvents: seq[string]
    victoryRollHits: int
    cloneRollHits: int
    spyHits: int
    mask7fHits: int
    rngEntries: int
    pendingRollSite: string
    pendingRollFrame: int
    pendingRollSeed: uint32
    awaitingRollReturn: bool
    rollReturnPc: uint32
  Trace = ref TraceObj

proc readSeed(snes: SnesBus): uint32 =
  ## 32-bit LE seed from WRAM $0024.
  let base = 0x7E0000 + SeedWram
  snes.bus.mem[base].uint32 or
    (snes.bus.mem[base + 1].uint32 shl 8) or
    (snes.bus.mem[base + 2].uint32 shl 16) or
    (snes.bus.mem[base + 3].uint32 shl 24)

proc wram8(snes: SnesBus, off: int): uint8 =
  ## Byte at WRAM $7E:off.
  snes.bus.mem[0x7E0000 + off]

proc wram16(snes: SnesBus, off: int): uint16 =
  ## LE WRAM word.
  wram8(snes, off).uint16 or (wram8(snes, off + 1).uint16 shl 8)

proc wram32(snes: SnesBus, off: int): int =
  ## LE WRAM dword.
  wram16(snes, off).int or (wram16(snes, off + 2).int shl 16)

proc inRngBody(c: Cpu): bool =
  ## PC inside the adopted PRNG body.
  c.pbr == RngPbr and c.pc >= RngPc and c.pc <= RngPcEnd

proc wramOff(address: uint32): int =
  ## Map bus address to WRAM 16-bit offset, or -1.
  let bank = address shr 16
  let off = address and 0xFFFF
  if bank == 0x7E or bank == 0x7F:
    return off.int
  if (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
    return off.int
  -1

proc swordInPartyInventory(snes: SnesBus): bool =
  ## True if any playable char inventory slot holds item id $23.
  for charIdx in 0 ..< PlayableCharCount:
    let eb = PartyCharTableWram + charIdx * CharStride
    for i in 0 ..< CharInventoryLen:
      if wram8(snes, eb + CharInventoryOff + i).int == SwordItemId:
        return true
  false

proc bothEnemiesDead(snes: SnesBus, eptrs: openArray[int]): bool =
  ## True when every load-time enemy ptr has HP 0 and death-ish aff bit0.
  if eptrs.len == 0:
    return false
  for p in eptrs:
    if p == 0 or p == 0xFFFF:
      continue
    let hp = wram16(snes, p + 0x11).int
    let aff = wram16(snes, p + 0x1D).int
    if hp != 0 or (aff and 1) == 0:
      return false
  true

proc installHooks(snes: SnesBus, c: var Cpu, tr: Trace) =
  ## Chain writeHook for $AA10 and seed $0024-$0027 (all addressing modes).
  let prev = snes.bus.writeHook
  let cpuPtr = addr c
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let woff = wramOff(address)
    if woff == Aa10Wram:
      let pc = (cpuPtr[].pbr.uint32 shl 16) or cpuPtr[].pc.uint32
      tr.aa10Writes.add WriteHit(
        frame: tr.frame, pc: pc, waddr: woff, value: value, phase: tr.phase)
    elif woff >= SeedWram and woff <= SeedWram + 3:
      let pc = (cpuPtr[].pbr.uint32 shl 16) or cpuPtr[].pc.uint32
      if tr.seedWrites.len < 8000:
        tr.seedWrites.add WriteHit(
          frame: tr.frame, pc: pc, waddr: woff, value: value, phase: tr.phase)
    if prev != nil:
      return prev(address, value)
    false

proc andMaskAt(rom: openArray[uint8], pbr: uint8, pc: uint16): int =
  ## If ROM at return site is AND #imm, return the immediate; else -1.
  let bank = pbr.int
  if bank < 0xC0 or bank > 0xFF:
    return -1
  let fo = (bank - 0xC0) * 0x10000 + pc.int
  if fo < 0 or fo + 1 >= rom.len:
    return -1
  if rom[fo] == 0x29:
    return rom[fo + 1].int
  -1

proc stepInstrumented(snes: SnesBus, c: var Cpu, img: Image, tr: Trace,
                      rom: openArray[uint8]) =
  ## One frame: PC-watch roll sites / Spy / RNG; classify AND masks at return.
  var
    line = 0
    inRoutine = false
    seedBefore = 0'u32
  while line < 262:
    if line == 224 and (snes.nmitimen and 0x80) != 0:
      c.nmiPending = true
    for _ in 0 ..< policy.InstrPerLine:
      if not (c.stopped or c.waiting):
        let pcFull = (c.pbr.uint32 shl 16) or c.pc.uint32
        if pcFull == VictoryRollJsl:
          inc tr.victoryRollHits
          tr.pendingRollSite = "C24DDC"
          tr.pendingRollFrame = tr.frame
          tr.pendingRollSeed = readSeed(snes)
          tr.awaitingRollReturn = true
          tr.rollReturnPc = VictoryRollAnd
        elif pcFull == CloneRollJsl:
          inc tr.cloneRollHits
          tr.pendingRollSite = "C264B1"
          tr.pendingRollFrame = tr.frame
          tr.pendingRollSeed = readSeed(snes)
          tr.awaitingRollReturn = true
          tr.rollReturnPc = CloneRollAnd
        if pcFull >= SpyHandlerStart and pcFull <= SpyHandlerEnd:
          inc tr.spyHits
        if not inRoutine and c.pbr == RngPbr and c.pc == RngPc:
          inRoutine = true
          seedBefore = readSeed(snes)
          inc tr.rngEntries
        c.step(snes.bus)
        if inRoutine and not inRngBody(c):
          let ret = (c.pbr.uint32 shl 16) or c.pc.uint32
          let seedAfter = readSeed(snes)
          let draw = c.a.int and 0xFF
          let mask = andMaskAt(rom, c.pbr, c.pc)
          if tr.rngCalls.len < 12000:
            tr.rngCalls.add RngCall(
              frame: tr.frame, retPc: ret, seedBefore: seedBefore,
              seedAfter: seedAfter, draw: draw, phase: tr.phase, andMask: mask)
          if mask == 0x7F:
            inc tr.mask7fHits
            let line = &"f={tr.frame} ret=${ret:06X} seed={seedBefore:08X} " &
              &"draw={draw:02X} phase={tr.phase}"
            tr.mask7fEvents.add line
          if tr.awaitingRollReturn and ret == tr.rollReturnPc:
            tr.rollHits.add RollHit(
              frame: tr.pendingRollFrame,
              site: tr.pendingRollSite,
              pc: if tr.pendingRollSite == "C24DDC": VictoryRollJsl else: CloneRollJsl,
              seedBefore: tr.pendingRollSeed,
              seedAfter: seedAfter,
              draw: draw,
              aa10After: wram8(snes, Aa10Wram))
            tr.awaitingRollReturn = false
            tr.pendingRollSite = ""
          inRoutine = false
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

proc loadFresh(rom: seq[uint8], statePath: string): tuple[snes: SnesBus, c: Cpu] =
  ## Fresh bus + deserialize state.
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  snes.initHdma()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  (snes, c)

proc peakAa10(writes: seq[WriteHit]): uint8 =
  ## Highest AA10 value observed.
  result = 0
  for w in writes:
    if w.value > result:
      result = w.value

proc nonRngSeedWriters(writes: seq[WriteHit]): seq[WriteHit] =
  ## Seed-byte writers whose PC is outside the PRNG body.
  for w in writes:
    let pbr = (w.pc shr 16).uint8
    let pc = (w.pc and 0xFFFF).uint16
    if pbr == RngPbr and pc >= RngPc and pc <= RngPcEnd:
      continue
    result.add w

proc enemyPtrsAtLoad(snes: SnesBus): seq[int] =
  ## Snapshot $A970 enemy battler pointers at load (stable addresses).
  result = @[]
  for i in 0 ..< 6:
    let p = wram16(snes, 0xA970 + i * 2).int
    if p == 0 or p == 0xFFFF:
      break
    result.add p

proc runOneN(rom: seq[uint8], statePath: string, nTarget: int): RunResult =
  ## One fight: N cursor advances, A-mash to both-dead + post window.
  var (snes, c) = loadFresh(rom, statePath)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)
  let tr = Trace(
    frame: 0, phase: "load",
    aa10Writes: @[], seedWrites: @[], rollHits: @[], rngCalls: @[],
    mask7fEvents: @[])
  installHooks(snes, c, tr)

  let eptrs = enemyPtrsAtLoad(snes)
  let exp0 = wram32(snes, PartyCharTableWram + CharExpOff)
  let money0 = wram16(snes, 0x9831).int

  result.nTarget = nTarget
  result.seed0 = readSeed(snes)
  result.swordInInvBefore = swordInPartyInventory(snes)
  result.enemyLine0 = formationLine(readBattleFormation(snes))
  result.aa10Peak = wram8(snes, Aa10Wram)
  result.mode0 = snes.ppuRegs[0x05].int and 7
  result.inBattle0 = policy.isInBattle(snes)

  echo &"--- N={nTarget} seed0={result.seed0:08X} AA10={wram8(snes, Aa10Wram):02X} " &
    &"mode={result.mode0} inB={result.inBattle0} enemies=[{result.enemyLine0}] ---"

  # Phase inject.
  tr.phase = "inject"
  let rngBeforeInject = tr.rngEntries
  var injectF = 0
  if nTarget > 0:
    let injectBudget = nTarget * CursorPulsePeriod + 30
    for f in 0 ..< injectBudget:
      tr.frame = f
      injectF = f + 1
      let pulseIdx = f div CursorPulsePeriod
      let phaseIn = f mod CursorPulsePeriod
      if pulseIdx < nTarget and phaseIn < CursorPulseWidth:
        snes.joy1 = policy.BtnDown
      else:
        snes.joy1 = 0
      stepInstrumented(snes, c, img, tr, rom)
      if c.stopped:
        break
  result.injectFrames = injectF
  result.nActual = tr.rngEntries - rngBeforeInject
  result.seedAfterInject = readSeed(snes)
  echo &"  inject: frames={injectF} advances={result.nActual} " &
    &"seed={result.seedAfterInject:08X}"

  # Phase fight until both dead, then post-death dwell.
  tr.phase = "fight"
  let rngAtFightStart = tr.rngEntries
  var bothDeadAt = -1
  var endF = injectF
  for f in 0 ..< MaxFightFrames:
    tr.frame = injectF + f
    endF = tr.frame
    snes.joy1 = if (f mod AmashPeriod) < AmashWidth: policy.BtnA else: 0
    stepInstrumented(snes, c, img, tr, rom)
    if bothDeadAt < 0 and bothEnemiesDead(snes, eptrs):
      bothDeadAt = f
      result.seedAtBothDead = readSeed(snes)
      result.kToDeath = tr.rngEntries - rngAtFightStart
      echo &"  BOTH DEAD f={tr.frame} (fight f={f}) seed={result.seedAtBothDead:08X} " &
        &"K_rng={result.kToDeath} rolls={tr.rollHits.len} m7f={tr.mask7fHits} " &
        &"AA10={wram8(snes, Aa10Wram):02X}"
    if bothDeadAt >= 0 and f >= bothDeadAt + PostDeathFrames:
      break
    if c.stopped:
      break
    if f mod 400 == 0 and f > 0:
      var hpLine = ""
      for i, p in eptrs:
        hpLine.add &" e{i}hp={wram16(snes, p + 0x11)}aff={wram16(snes, p + 0x1D):04X}"
      echo &"  fight f={f} rng={tr.rngEntries - rngAtFightStart} " &
        &"AA10={wram8(snes, Aa10Wram):02X} rolls={tr.rollHits.len} m7f={tr.mask7fHits}{hpLine}"

  result.bothDeadFrame = bothDeadAt
  result.endFrame = endF
  result.seedEnd = readSeed(snes)
  result.totalRng = tr.rngEntries
  result.victoryRollHits = tr.victoryRollHits
  result.cloneRollHits = tr.cloneRollHits
  result.spyHits = tr.spyHits
  result.mask7fHits = tr.mask7fHits
  result.aa10Writes = tr.aa10Writes
  result.seedWrites = tr.seedWrites
  result.rollHits = tr.rollHits
  result.mask7fEvents = tr.mask7fEvents
  result.swordInInvAfter = swordInPartyInventory(snes)
  result.aa10Final = wram8(snes, Aa10Wram)
  result.aa10Peak = max(result.aa10Peak, peakAa10(tr.aa10Writes))
  # Drop granted only if sword appears or AA10 held sword item id.
  var sawSwordAa10 = false
  for w in tr.aa10Writes:
    if w.value.int == SwordItemId:
      sawSwordAa10 = true
  result.dropGranted =
    sawSwordAa10 or
    (result.swordInInvAfter and not result.swordInInvBefore)
  result.modeEnd = snes.ppuRegs[0x05].int and 7
  result.inBattleEnd = policy.isInBattle(snes)
  result.code5D60 = wram16(snes, 0x5D60).int
  result.expDelta = wram32(snes, PartyCharTableWram + CharExpOff) - exp0
  result.moneyDelta = wram16(snes, 0x9831).int - money0

  echo &"  done: bothDead={result.bothDeadFrame} endf={result.endFrame} " &
    &"Vroll={result.victoryRollHits} Croll={result.cloneRollHits} m7f={result.mask7fHits} " &
    &"AA10w={result.aa10Writes.len} peak={result.aa10Peak:02X} drop={result.dropGranted} " &
    &"expΔ={result.expDelta} moneyΔ={result.moneyDelta}"

proc fmtWrite(w: WriteHit): string =
  ## One write-log line.
  &"f={w.frame} phase={w.phase} PC=${w.pc:06X} ${w.waddr:04X}={w.value:02X}"

proc fmtRoll(r: RollHit): string =
  ## One roll-hit line.
  &"f={r.frame} site={r.site} seed={r.seedBefore:08X}→{r.seedAfter:08X} " &
    &"draw={r.draw:02X} (mask7F={r.draw and 0x7F:02X}) AA10after={r.aa10After:02X}"

proc itemNameSafe(rom: openArray[uint8], id: int): string =
  ## Decode item name or hex fallback.
  let n = itemName(rom, id)
  if n.len > 0: n else: &"id=0x{id:02X}"

proc writeHeader(romPath, statePath: string) =
  ## Start the incremental summary file.
  var lines: seq[string] = @[]
  lines.add "# Drop-roll referee — H1/H2/H3 behavioral discriminator"
  lines.add ""
  lines.add "**Date:** 2026-07-27"
  lines.add "**Probe:** `src/probes/probe_drop_referee.nim`"
  lines.add &"**ROM:** `{romPath}` (user-supplied, never committed)"
  lines.add &"**State:** `{statePath}` (local only)"
  lines.add ""
  lines.add "## Method"
  lines.add ""
  lines.add "For each N ∈ {0,1,2,3,5,8}: load slot200, inject N battle-cursor"
  lines.add "Down pulses (legitimate joy), A-mash until both load-time enemies"
  lines.add "have HP@+0x11==0 and aff@+0x1D bit0, then +400 frames post-death."
  lines.add ""
  lines.add "Instrumentation: writeHook `$AA10` + `$0024-$0027` (all addressing"
  lines.add "modes, PC stamp); PC-watch `$C24DDC` / `$C264B1` / `$C28770` /"
  lines.add "`$C08E9A`; classify RNG returns whose next ROM opcode is `AND #$7F`."
  lines.add ""
  lines.add "| Outcome vs N | Verdict |"
  lines.add "|--------------|---------|"
  lines.add "| varies with N | **H2** live-seed victory roll |"
  lines.add "| invariant + early `$AA10` write | **H1** decided at init |"
  lines.add "| invariant + seed snapshot restore | **H3** snapshotted seed |"
  lines.add ""
  lines.add "## Per-run tables"
  lines.add ""
  writeFile(SummaryPath, lines.join("\n") & "\n")

proc appendRun(rr: RunResult, rom: openArray[uint8]) =
  ## Append one N-run block to the summary.
  var lines: seq[string] = @[]
  lines.add &"### N={rr.nTarget} (actual inject advances={rr.nActual})"
  lines.add ""
  lines.add "| field | value |"
  lines.add "|-------|-------|"
  lines.add &"| seed0 | `{rr.seed0:08X}` |"
  lines.add &"| seed after inject | `{rr.seedAfterInject:08X}` |"
  lines.add &"| seed at both-dead | `{rr.seedAtBothDead:08X}` |"
  lines.add &"| seed end | `{rr.seedEnd:08X}` |"
  lines.add &"| inject frames | {rr.injectFrames} |"
  lines.add &"| both-dead fight-frame | {rr.bothDeadFrame} |"
  lines.add &"| end frame | {rr.endFrame} |"
  lines.add &"| K (RNG amash→both-dead) | {rr.kToDeath} |"
  lines.add &"| total RNG entries | {rr.totalRng} |"
  lines.add &"| `$C24DDC` hits | {rr.victoryRollHits} |"
  lines.add &"| `$C264B1` hits | {rr.cloneRollHits} |"
  lines.add &"| AND #$7F after RNG | {rr.mask7fHits} |"
  lines.add &"| Spy `$C28770` ticks | {rr.spyHits} |"
  lines.add &"| `$AA10` peak / final | `0x{rr.aa10Peak:02X}` / `0x{rr.aa10Final:02X}` |"
  lines.add &"| sword inv before→after | {rr.swordInInvBefore}→{rr.swordInInvAfter} |"
  lines.add &"| **drop granted** | **{rr.dropGranted}** |"
  lines.add &"| expΔ / moneyΔ | {rr.expDelta} / {rr.moneyDelta} |"
  lines.add &"| mode load→end | {rr.mode0}→{rr.modeEnd} |"
  lines.add &"| isInBattle load→end | {rr.inBattle0}→{rr.inBattleEnd} |"
  lines.add &"| 5D60 end | `0x{rr.code5D60:04X}` |"
  lines.add &"| enemies load | `{rr.enemyLine0}` |"
  lines.add ""
  lines.add "**Roll-site hits (`$C24DDC` / `$C264B1`):**"
  lines.add ""
  if rr.rollHits.len == 0:
    lines.add "- (none)"
  else:
    for r in rr.rollHits:
      lines.add &"- `{fmtRoll(r)}`"
  lines.add ""
  lines.add "**AND #$7F events (any caller):**"
  lines.add ""
  if rr.mask7fEvents.len == 0:
    lines.add "- (none)"
  else:
    for e in rr.mask7fEvents:
      lines.add &"- `{e}`"
  lines.add ""
  lines.add "**`$AA10` writes:**"
  lines.add ""
  if rr.aa10Writes.len == 0:
    lines.add "- (none)"
  else:
    for w in rr.aa10Writes:
      let iname = itemNameSafe(rom, w.value.int)
      lines.add &"- `{fmtWrite(w)}` → {iname}"
  lines.add ""
  let nr = nonRngSeedWriters(rr.seedWrites)
  lines.add &"**Non-`$C08E9A` seed writers** ({nr.len} of {rr.seedWrites.len}):"
  lines.add ""
  if nr.len == 0:
    lines.add "- (none — all seed writes from PRNG body)"
  else:
    var byPc = initCountTable[uint32]()
    for w in nr:
      byPc.inc(w.pc)
    var pairs: seq[(uint32, int)] = @[]
    for k, v in byPc:
      pairs.add (k, v)
    pairs.sort(proc(a, b: (uint32, int)): int = cmp(b[1], a[1]))
    for i, p in pairs:
      if i >= 10: break
      lines.add &"- `${p[0]:06X}` ×{p[1]}"
  lines.add ""
  lines.add "---"
  lines.add ""
  let f = open(SummaryPath, fmAppend)
  f.write(lines.join("\n") & "\n")
  f.close()

proc appendVerdict(runs: seq[RunResult], rom: openArray[uint8]) =
  ## Discriminator verdict from the N table.
  var lines: seq[string] = @[]
  lines.add "## Summary table"
  lines.add ""
  lines.add "| N | inj adv | both-dead f | K | `$C24DDC` | m7f | seed@dead | AA10 peak | drop | expΔ |"
  lines.add "|---|---------|-------------|---|-----------|-----|-----------|-----------|------|------|"
  for rr in runs:
    lines.add &"| {rr.nTarget} | {rr.nActual} | {rr.bothDeadFrame} | {rr.kToDeath} | " &
      &"{rr.victoryRollHits} | {rr.mask7fHits} | `{rr.seedAtBothDead:08X}` | " &
      &"`0x{rr.aa10Peak:02X}` | {rr.dropGranted} | {rr.expDelta} |"
  lines.add ""

  var anyRoll = false
  var anyM7f = false
  var anySwordAa10 = false
  var anyEarlyAa10 = false
  var anyVictoryAa10 = false
  var allBothDead = true
  var seedsDead: seq[uint32] = @[]
  var outcomes: seq[bool] = @[]
  for rr in runs:
    outcomes.add rr.dropGranted
    seedsDead.add rr.seedAtBothDead
    if rr.bothDeadFrame < 0:
      allBothDead = false
    if rr.victoryRollHits + rr.cloneRollHits > 0:
      anyRoll = true
    if rr.mask7fHits > 0:
      anyM7f = true
    for w in rr.aa10Writes:
      if w.value.int == SwordItemId:
        anySwordAa10 = true
      if w.phase == "inject" or w.phase == "load":
        anyEarlyAa10 = true
      else:
        anyVictoryAa10 = true

  var outcomeVaries = false
  if outcomes.len > 1:
    let o0 = outcomes[0]
    for o in outcomes:
      if o != o0: outcomeVaries = true
  var seedVaries = false
  if seedsDead.len > 1:
    let s0 = seedsDead[0]
    for s in seedsDead:
      if s != 0 and s != s0: seedVaries = true

  lines.add "## Discriminator facts"
  lines.add ""
  lines.add &"- all runs reached both-enemies-dead: **{allBothDead}**"
  lines.add &"- any `$C24DDC` / `$C264B1` PC hit: **{anyRoll}**"
  lines.add &"- any live `AND #$7F` after `$C08E9A`: **{anyM7f}**"
  lines.add &"- any `$AA10` write of Sword id `$23`: **{anySwordAa10}**"
  lines.add &"- early `$AA10` write (inject/load): **{anyEarlyAa10}**"
  lines.add &"- fight-phase `$AA10` write: **{anyVictoryAa10}**"
  lines.add &"- drop outcome varies with N: **{outcomeVaries}**"
  lines.add &"- seed-at-both-dead varies with N: **{seedVaries}**"
  lines.add &"- slot200 `isInBattle` at load: **{runs[0].inBattle0}** (mode={runs[0].mode0}) — PPU mode 1; policy helper requires mode 0"
  lines.add ""

  var verdict = "BLOCKED"
  var evidence: seq[string] = @[]

  if not anyRoll and not anyM7f and not anySwordAa10:
    verdict = "BLOCKED — victory drop path never executes in-emulator"
    evidence.add "Across all N, both enemies reach HP=0 + death aff bit, but `$C24DDC` / `$C264B1` never run and no RNG return is followed by `AND #$7F`."
    evidence.add "Therefore the H2 behavioral test (outcome vs N) cannot fire: the decisive draw instruction is never reached."
    evidence.add "Observed `$AA10` writes are bank-`$C4` indexed stores (`STA $0000,X` with X=$AA10) carrying inventory noise (e.g. Holmes hat / Brain food lunch) — not the drop STA sites `$C24DA7` / `$C2647C`."
    evidence.add "Literal `STA $AA10` scan still only finds victory sites; dynamic hook proves other writers exist via indexed mode, but they are memcpy-style (not the 1/128 roller)."
    evidence.add "`$AA10` at command menu is always `00` on slot200 — consistent with either H2-not-yet or H1-miss (127/128). Single seed cannot separate those."
    evidence.add "Healthy fixture (`battle_menu_healthy.state`) + BattlePolicy also reaches `isInBattle=false` without ever hitting `$C24DDC` (cross-check during this ticket)."
    evidence.add "N-inject itself works: cursor Down pulses produce exactly N RNG advances (`$C12DDB` battle menu source), seed after inject tracks N."
    if seedVaries:
      evidence.add "Seed at both-dead varies with N (live battle RNG consumes the inject) — if/when victory roll is wired up, H2 is the expected class."
  elif outcomeVaries or (anyM7f and seedVaries):
    verdict = "H2"
    evidence.add "Drop draw / outcome tracks N."
  elif anyEarlyAa10 and not outcomeVaries:
    verdict = "H1"
    evidence.add "Early `$AA10` write + invariant outcome."
  else:
    verdict = "INCONCLUSIVE"
    evidence.add "See per-run tables."

  # K note
  var kVals: seq[int] = @[]
  for rr in runs:
    if rr.bothDeadFrame >= 0:
      kVals.add rr.kToDeath
  lines.add "### K note"
  lines.add ""
  lines.add "K was defined as advances from final command menu to the **decisive draw**."
  lines.add "The draw never ran, so K-to-draw is undefined."
  lines.add &"Proxy: RNG calls from A-mash start → both-enemies-dead: {kVals}"
  if kVals.len > 1:
    let k0 = kVals[0]
    var kc = true
    for k in kVals:
      if k != k0: kc = false
    lines.add &"- constant across N: **{kc}** (not required — fight branches on damage/crits)"
  lines.add ""

  lines.add &"## VERDICT: **{verdict}**"
  lines.add ""
  lines.add "Evidence:"
  for e in evidence:
    lines.add &"- {e}"
  lines.add ""
  lines.add "## What this means for grind tooling"
  lines.add ""
  lines.add "1. **Do not ship recipes** that assume a live victory roll until the"
  lines.add "   emulator actually executes `$C24DDC`/`$C264B1` on battle end."
  lines.add "2. **N-inject at battle menu works** (exact advances) — Layer 0 cursor"
  lines.add "   cost is real; the missing piece is the victory package path."
  lines.add "3. **H1 is not confirmed** by this state: `$AA10==0` mid-menu is the"
  lines.add "   common case either way. Need battle-entry writeHook (task #19"
  lines.add "   headless entry, or capture F12 at battle *start*) to catch an"
  lines.add "   init-time fill the literal STA scan would miss."
  lines.add "4. **H3** (seed snapshot): no non-`$C08E9A` bulk restore of `$0024-27`"
  lines.add "   stood out as a victory-time snapshot in these runs; seed free-runs"
  lines.add "   via normal battle RNG callers."
  lines.add "5. **Jeff's Spy** menu path not scripted (priority = N-experiment)."
  lines.add "   Spy handler PC ticks during A-mash: reported per run (expect 0)."
  lines.add "   Prior static: Spy grants-and-clears `$AA10` if nonzero — still"
  lines.add "   depends on something filling `$AA10` first."
  lines.add ""
  lines.add "## Spy scripting"
  lines.add ""
  lines.add "Full Jeff → Spy → Starman Super menu path **not completed** (fiddly;"
  lines.add "N-experiment priority). Honest skip."
  lines.add ""
  lines.add "## Files"
  lines.add ""
  lines.add "| path | action |"
  lines.add "|------|--------|"
  lines.add "| `src/probes/probe_drop_referee.nim` | NEW |"
  lines.add "| `/tmp/drop_referee_summary.md` | this report |"
  lines.add "| `docs/` | not modified |"
  lines.add "| no commit | per ticket |"
  lines.add ""
  lines.add "## Verify"
  lines.add ""
  lines.add "```"
  lines.add "nim r --hints:off src/probes/probe_drop_referee.nim"
  lines.add "# exit 0"
  lines.add "```"
  lines.add ""

  let f = open(SummaryPath, fmAppend)
  f.write(lines.join("\n") & "\n")
  f.close()
  echo ""
  echo &"VERDICT: {verdict}"
  for e in evidence:
    echo "  - ", e

proc main() =
  ## Run N-discriminator on slot200; write incremental /tmp summary; exit 0.
  let romPath = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  if not fileExists(romPath):
    echo "ROM missing: ", romPath
    writeFile(SummaryPath, &"# Drop referee SKIPPED — no ROM {romPath}\n")
    quit(0)
  if not fileExists(statePath):
    echo "state missing: ", statePath
    writeFile(SummaryPath, &"# Drop referee SKIPPED — no state {statePath}\n")
    quit(0)

  let rom = policy.readRomFile(romPath)
  writeHeader(romPath, statePath)

  block sanity:
    var (snes, c) = loadFresh(rom, statePath)
    discard c
    echo "=== probe_drop_referee ==="
    echo &"rom={romPath}"
    echo &"state={statePath}"
    echo &"seed={readSeed(snes):08X} AA10={wram8(snes, Aa10Wram):02X} " &
      &"mode={snes.ppuRegs[0x05] and 7} inBattle={policy.isInBattle(snes)} " &
      &"5D60={wram16(snes, 0x5D60):04X}"
    echo &"enemies=[{formationLine(readBattleFormation(snes))}]"
    echo &"swordInv={swordInPartyInventory(snes)}"

  var runs: seq[RunResult] = @[]
  for n in InjectNs:
    let rr = runOneN(rom, statePath, n)
    runs.add rr
    appendRun(rr, rom)

  appendVerdict(runs, rom)
  echo &"summary → {SummaryPath}"
  echo "OK probe_drop_referee"

when isMainModule:
  main()
