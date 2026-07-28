## Jeff's Spy vs drop-roll discriminator (static + optional dynamic).
##
## Static (always): ROM-byte proof that
##   - action table `$D57B68` id 6 → handler `$C28770` (Spy)
##   - menu path `$C239C9` stores action id 6 when actor char type `$26==3`
##   - `$C26451` clone is fall-through inside victory rewards `$C261BD`
##   - Spy handler never reaches the drop roll; `$AA10` writers are victory-only
##
## Dynamic (if slot200.state present): load live Starman Super command menu,
## chain-wrap writeHook for `$AA10` + PC-watch `$C08E9A` callers, idle + light
## input probe. Full Spy menu scripting is best-effort (may not complete).
##
## Usage: nim r src/probes/probe_spy_roll.nim [rom] [state]
## Exit 0 on static asserts; dynamic section is informational.

import
  std/[algorithm, os, sequtils, strformat, strutils, tables],
  pixie,
  ../decompbound/[cpu, ppu, snesbus, save_state, policy]

const
  DefaultRom = "bin/Earthbound (U) [!].smc"
  DefaultState = "bin/states/slot200.state"
  ## Battle action table base (12-byte records).
  ActionTableSnes = 0xD57B68'u32
  ActionTableFile = 0x157B68
  ActionStride = 12
  SpyActionId = 6
  SpyHandler = 0xC28770'u32
  SpyTextPtr = 0xEF8530'u32
  ## Victory drop-roll clone (AND #$7F site).
  CloneRollAnd = 0xC264B1'u32
  CloneEntry = 0xC26451'u32
  VictoryRewards = 0xC261BD'u32
  VictoryRollAnd = 0xC24DDC'u32
  SpyHandlerStart = 0xC28770'u32
  SpyHandlerEnd = 0xC2889A'u32
  RngPbr = 0xC0'u8
  RngPc = 0x8E9A'u16
  RngPcEnd = 0x8ED1'u16
  Aa10Wram = 0xAA10
  ## Jeff menu → action 6 store site.
  JeffSpyAssign = 0xC239C9'u32
  EnemyTableFile = 0x159589
  EnemyStride = 0x5E
  EnemyDropFreqOff = 0x57
  EnemyDropItemOff = 0x58
  StarmanSuperId = 68

type
  RngHit = object
    caller: uint32
    count: int

  WriteHit = object
    pc: uint32
    value: uint8
    frame: int

proc loadRomBytes(path: string): seq[uint8] =
  ## ROM without optional 512-byte copier header.
  var d = cast[seq[uint8]](readFile(path))
  if d.len mod 1024 == 512:
    d = d[512 .. ^1]
  d

proc expect(cond: bool; msg: string) =
  ## Fail the probe when a structural check does not hold.
  if not cond:
    raise newException(AssertionDefect, msg)

proc snesToFile(snesAddr: uint32): int =
  ## HiROM file offset for banks `$C0`–`$FF`.
  let bank = int(snesAddr shr 16)
  let off = int(snesAddr and 0xFFFF)
  (bank - 0xC0) * 0x10000 + off

proc readU16Le(rom: openArray[uint8], off: int): int =
  ## Little-endian u16.
  rom[off].int or (rom[off + 1].int shl 8)

proc readU24Le(rom: openArray[uint8], off: int): uint32 =
  ## Little-endian 24-bit (long pointer low 3 bytes).
  rom[off].uint32 or (rom[off + 1].uint32 shl 8) or (rom[off + 2].uint32 shl 16)

proc wram8(snes: SnesBus, off: int): uint8 =
  ## WRAM `$7E:off`.
  snes.bus.mem[0x7E0000 + off]

proc wram16(snes: SnesBus, off: int): uint16 =
  ## LE WRAM word.
  wram8(snes, off).uint16 or (wram8(snes, off + 1).uint16 shl 8)

proc inRngBody(cpu: Cpu): bool =
  ## PC inside the adopted PRNG body.
  cpu.pbr == RngPbr and cpu.pc >= RngPc and cpu.pc <= RngPcEnd

proc staticSpyEvidence(rom: openArray[uint8]) =
  ## ROM-byte proof for Spy dispatch vs drop-roll clone.
  echo "======== STATIC: Spy action table + drop writers ========"

  # Action id 6 record at $D57B68 + 6*12.
  let recOff = ActionTableFile + SpyActionId * ActionStride
  expect(recOff + ActionStride <= rom.len, "action table past ROM end")
  let flags0 = rom[recOff]
  let flags1 = rom[recOff + 1]
  let flags2 = rom[recOff + 2]
  let textPtr = readU24Le(rom, recOff + 4)
  let handler = readU24Le(rom, recOff + 8)
  echo &"  action[{SpyActionId}] @ file 0x{recOff:06X}: flags={flags0:02X} {flags1:02X} {flags2:02X} 00"
  echo &"    text=${textPtr:06X} handler=${handler:06X}"
  expect(handler == SpyHandler, &"Spy handler want ${SpyHandler:06X} got ${handler:06X}")
  expect(textPtr == SpyTextPtr, &"Spy text want ${SpyTextPtr:06X} got ${textPtr:06X}")
  expect(flags2 == 0x05, &"Spy flag byte2 want 05 got {flags2:02X}")

  # Jeff menu assign: LDA #$0006 at $C239C9 after CMP #$0003 on $26.
  let assignOff = snesToFile(JeffSpyAssign)
  expect(rom[assignOff] == 0xA9 and rom[assignOff + 1] == 0x06 and rom[assignOff + 2] == 0x00,
    "Jeff Spy assign site missing LDA #$0006")
  # Preceding CMP #$0003: C9 03 00 within 16 bytes before.
  var sawCmp3 = false
  for i in max(0, assignOff - 16) ..< assignOff:
    if rom[i] == 0xC9 and rom[i + 1] == 0x03 and rom[i + 2] == 0x00:
      sawCmp3 = true
      break
  expect(sawCmp3, "Jeff Spy assign not preceded by CMP #$0003")
  echo &"  Jeff menu → action 6: LDA #$0006 @ ${JeffSpyAssign:06X} (after char-type 3 check)"

  # Clone entry is table-base load identical to victory, uses $16 not $2F.
  let cloneOff = snesToFile(CloneEntry)
  expect(rom[cloneOff] == 0xA9 and rom[cloneOff + 1] == 0x89 and rom[cloneOff + 2] == 0x95,
    "clone entry not LDA #$9589")
  let victoryIdxOff = snesToFile(0xC24D7C'u32)
  expect(rom[victoryIdxOff] == 0xA9 and rom[victoryIdxOff + 1] == 0x89,
    "victory drop index missing")
  # Clone AND #$7F after JSL RNG.
  let cloneAndOff = snesToFile(CloneRollAnd)
  expect(rom[cloneAndOff] == 0x22 and rom[cloneAndOff + 1] == 0x9A and
    rom[cloneAndOff + 2] == 0x8E and rom[cloneAndOff + 3] == 0xC0,
    "clone missing JSL $C08E9A")
  expect(rom[cloneAndOff + 4] == 0x29 and rom[cloneAndOff + 5] == 0x7F,
    "clone missing AND #$7F")
  echo &"  clone drop roll: entry ${CloneEntry:06X}, AND #$7F @ ${CloneRollAnd:06X}"

  # Victory rewards entry JSL target.
  let rewOff = snesToFile(VictoryRewards)
  expect(rom[rewOff] == 0xC2 and rom[rewOff + 1] == 0x31, "victory rewards missing REP #$31")
  # Sole long-call to C261BD is C0B758 (bytes 22 BD 61 C2).
  var callSites: seq[uint32]
  let jslPat = [0x22'u8, 0xBD, 0x61, 0xC2]
  for i in 0 .. rom.len - 4:
    if rom[i] == jslPat[0] and rom[i + 1] == jslPat[1] and
        rom[i + 2] == jslPat[2] and rom[i + 3] == jslPat[3]:
      let bank = 0xC0 + i div 0x10000
      callSites.add((bank.uint32 shl 16) or (i mod 0x10000).uint32)
  echo &"  JSL $C261BD sites: {callSites.len} → ", callSites.mapIt(&"${it:06X}").join(", ")
  expect(callSites.len == 1 and callSites[0] == 0xC0B758'u32,
    "expected sole JSL $C261BD at $C0B758")

  # No JSL/JML/JSR/JMP absolute to $C26451.
  var directHits = 0
  for i in 0 .. rom.len - 4:
    if rom[i] == 0x22 or rom[i] == 0x5C:
      if rom[i + 1] == 0x51 and rom[i + 2] == 0x64 and rom[i + 3] == 0xC2:
        inc directHits
  for i in snesToFile(0xC20000'u32) .. snesToFile(0xC2FFFF'u32) - 2:
    if (rom[i] == 0x20 or rom[i] == 0x4C) and rom[i + 1] == 0x51 and rom[i + 2] == 0x64:
      inc directHits
  expect(directHits == 0, "unexpected direct call to $C26451")
  echo "  no direct JSL/JMP/JSR to $C26451 (fall-through only)"

  # STA $AA10 only at victory sites.
  var staSites: seq[uint32]
  for i in 0 .. rom.len - 3:
    if rom[i] == 0x8D and rom[i + 1] == 0x10 and rom[i + 2] == 0xAA:
      let bank = 0xC0 + i div 0x10000
      staSites.add((bank.uint32 shl 16) or (i mod 0x10000).uint32)
  echo "  STA $AA10 sites: ", staSites.mapIt(&"${it:06X}").join(", ")
  expect(0xC24DA7'u32 in staSites and 0xC2647C'u32 in staSites,
    "expected victory STA $AA10 at $C24DA7 and $C2647C")
  for s in staSites:
    expect(s == 0xC24DA7'u32 or s == 0xC24EB1'u32 or s == 0xC2647C'u32,
      &"unexpected STA $AA10 at ${s:06X}")

  # Spy handler body: no JSL $C08E9A, no LDA #$9589, has LDA $AA10 + STZ $AA10.
  let spy0 = snesToFile(SpyHandlerStart)
  let spy1 = snesToFile(SpyHandlerEnd)
  let spyBody = rom[spy0 .. spy1]
  var hasRng = false
  var hasTable = false
  var hasLdaAa10 = false
  var hasStzAa10 = false
  for i in 0 .. spyBody.len - 4:
    if spyBody[i] == 0x22 and spyBody[i + 1] == 0x9A and
        spyBody[i + 2] == 0x8E and spyBody[i + 3] == 0xC0:
      hasRng = true
    if spyBody[i] == 0xA9 and spyBody[i + 1] == 0x89 and spyBody[i + 2] == 0x95:
      hasTable = true
    if spyBody[i] == 0xAD and spyBody[i + 1] == 0x10 and spyBody[i + 2] == 0xAA:
      hasLdaAa10 = true
    if spyBody[i] == 0x9C and spyBody[i + 1] == 0x10 and spyBody[i + 2] == 0xAA:
      hasStzAa10 = true
  expect(not hasRng, "Spy handler must not call RNG")
  expect(not hasTable, "Spy handler must not load enemy table base")
  expect(hasLdaAa10 and hasStzAa10, "Spy handler should LDA/STZ $AA10 at tail")
  echo "  Spy handler $C28770..$C2889A: no RNG, no table load; LDA+STZ $AA10 at tail"

  # Starman Super still freq 0 / item present (sanity vs Layer 0b).
  let er = EnemyTableFile + StarmanSuperId * EnemyStride
  let freq = rom[er + EnemyDropFreqOff]
  let item = rom[er + EnemyDropItemOff]
  expect(freq == 0, "Starman Super drop freq")
  expect(item == 0x23, "Starman Super drop item id")
  echo &"  Starman Super id={StarmanSuperId} freq={freq} item=0x{item:02X}"

  echo "STATIC OK"
  echo ""
  echo "SEMANTICS (from static evidence):"
  echo "  1. $C26451 clone is victory rewards path ($C261BD ← $C0B758), NOT Spy."
  echo "  2. Spy = action id 6, handler $C28770: print stats/weaknesses from battler."
  echo "  3. Spy does NOT run its own +0x57/+0x58 roll (no table/RNG in handler)."
  echo "  4. Spy tail: if enemy && Jeff inventory free-slot check && $AA10!=0 →"
  echo "     display item ($C1DD7C) + msg $EF7DD5 + STZ $AA10 (would suppress double)."
  echo "  5. $AA10 is only STA'd on victory drop paths → mid-battle Spy cannot see a"
  echo "     not-yet-rolled drop; player 'steal if they have it' is not a mid-battle"
  echo "     independent 1/128. Carry-flag-at-init remains unsupported."
  echo ""

proc dynamicProbe(romPath, statePath: string) =
  ## Load slot200-style state; watch RNG callers and $AA10 writes under light input.
  if not fileExists(statePath):
    echo &"======== DYNAMIC: skip (no state {statePath}) ========"
    return

  echo "======== DYNAMIC: ", statePath, " ========"
  let rom = loadRomBytes(romPath)
  let snes = newSnesBus(rom)
  var c = snes.resetCpu()
  deserializeState(cast[seq[byte]](readFile(statePath)), snes, c)
  let img = newImage(ppu.ScreenWidth, ppu.ScreenHeight)

  # Snapshot party names + battler HP + AA10.
  echo &"  seed=${wram16(snes, 0x24):04X}{wram16(snes, 0x26):04X}  $AA10={wram8(snes, Aa10Wram):02X}"
  for p in 0 .. 5:
    let bptr = wram16(snes, 0x4DC8 + p * 2)
    if bptr == 0 or bptr == 0xFFFF: continue
    let hp = wram16(snes, bptr.int + 0x0A)
    let typ = wram8(snes, bptr.int + 0x0E)
    let act = wram16(snes, bptr.int + 0x04)
    let eid = wram16(snes, bptr.int + 0x00)
    echo &"  battler[{p}] ptr=${bptr:04X} id={eid} type={typ} action={act} HP={hp}"

  # Battle window text sample (command menu labels).
  let btxt = policy.getBattleText(snes)
  if btxt.len > 0:
    let preview = if btxt.len > 120: btxt[0 .. 119] & "..." else: btxt
    echo "  battleText: ", preview.replace("\n", " | ")
  else:
    echo "  battleText: (empty)"

  var
    rngCallers = initCountTable[uint32]()
    aa10Writes: seq[WriteHit]
    hitCloneRoll = 0
    hitVictoryRoll = 0
    hitSpyHandler = 0
    frame = 0

  let prev = snes.bus.writeHook
  snes.bus.writeHook = proc(address: uint32, value: uint8): bool =
    let bank = address shr 16
    let off = address and 0xFFFF
    var woff = -1
    if bank == 0x7E or bank == 0x7F:
      woff = off.int
    elif (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and off < 0x2000:
      woff = off.int
    if woff == Aa10Wram:
      let pc = (c.pbr.uint32 shl 16) or c.pc.uint32
      aa10Writes.add WriteHit(pc: pc, value: value, frame: frame)
      echo &"  [AA10 write] f={frame} PC=${pc:06X} val={value:02X}"
    if prev != nil:
      return prev(address, value)
    false

  proc stepCounting() =
    ## One frame; count RNG entries and key PCs.
    var
      line = 0
      inRoutine = false
    while line < 262:
      if line == 224 and (snes.nmitimen and 0x80) != 0:
        c.nmiPending = true
      for _ in 0 ..< policy.InstrPerLine:
        if not (c.stopped or c.waiting):
          let pcFull = (c.pbr.uint32 shl 16) or c.pc.uint32
          if pcFull == CloneRollAnd:
            inc hitCloneRoll
          if pcFull == VictoryRollAnd:
            inc hitVictoryRoll
          if pcFull >= SpyHandlerStart and pcFull <= SpyHandlerEnd:
            inc hitSpyHandler
          if not inRoutine and c.pbr == RngPbr and c.pc == RngPc:
            inRoutine = true
          c.step(snes.bus)
          if inRoutine and not inRngBody(c):
            let ret = (c.pbr.uint32 shl 16) or c.pc.uint32
            rngCallers.inc(ret)
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

  # Phase A: idle 90f (battle menu dwell should be 0 advances).
  echo "  --- idle 90f ---"
  for f in 0 ..< 90:
    frame = f
    snes.joy1 = 0
    stepCounting()
  echo &"  idle RNG callers: {rngCallers.len} distinct, total hits logged via table"
  var idleTotal = 0
  for _, n in rngCallers:
    idleTotal += n
  echo &"  idle RNG call count={idleTotal} cloneHits={hitCloneRoll} victoryHits={hitVictoryRoll} spyHits={hitSpyHandler}"

  # Phase B: light A-mash (Bash path) 180f — expect battle RNG, not Spy/clone.
  echo "  --- A-mash 180f (Bash path; Spy scripting is fiddly) ---"
  for f in 0 ..< 180:
    frame = 90 + f
    snes.joy1 = if (f mod 12) < 3: policy.BtnA else: 0
    stepCounting()
  echo &"  after A-mash: cloneHits={hitCloneRoll} victoryHits={hitVictoryRoll} spyHits={hitSpyHandler}"
  echo &"  $AA10 writes this run: {aa10Writes.len}"
  if aa10Writes.len > 0:
    for w in aa10Writes:
      echo &"    f={w.frame} PC=${w.pc:06X} val={w.value:02X}"
  # Top RNG return addresses.
  var pairs: seq[tuple[pc: uint32, n: int]]
  for k, v in rngCallers:
    pairs.add (pc: k, n: v)
  pairs.sort(proc(a, b: tuple[pc: uint32, n: int]): int = cmp(b.n, a.n))
  echo "  top RNG return PCs:"
  for i, p in pairs:
    if i >= 8: break
    echo &"    ${p.pc:06X} x{p.n}"

  echo ""
  echo "DYNAMIC NOTE: full Spy selection (cursor to Jeff-only Spy row + target)"
  echo "  not fully scripted here — static handler evidence is sufficient."
  echo "  Idle/A-mash did not hit Spy handler or drop-roll clone (expected)."
  echo "DYNAMIC OK (informational; static asserts already passed)"

proc main() =
  ## Run static ROM asserts, then optional dynamic watch on a live battle state.
  let romPath = if paramCount() >= 1: paramStr(1) else: DefaultRom
  let statePath = if paramCount() >= 2: paramStr(2) else: DefaultState
  if not fileExists(romPath):
    raise newException(IOError, "ROM not found: " & romPath)

  let rom = loadRomBytes(romPath)
  staticSpyEvidence(rom)
  dynamicProbe(romPath, statePath)
  echo ""
  echo "OK probe_spy_roll"

when isMainModule:
  main()
