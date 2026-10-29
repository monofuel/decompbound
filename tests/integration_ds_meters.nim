import
  std/[os, strutils],
  ../src/decompbound/[asm_parse, cpu, ds_companion, party_sram, party_wram,
    png_state, rom_pipeline, save_state, snesbus]

const
  Wram = 0x7E0000'u32
  Caller = 0x1E00'u32
  BattleDisplayRoster = 0x986F
  FastMeters = 0x9698
  HpFraction = 0x43
  PpFraction = 0x49
  StepLimit = 100000

proc putWord(snes: SnesBus, address: int, value: int) =
  ## Initialize generated WRAM fields without loading game-derived fixtures.
  snes.bus.write8(Wram + address.uint32, uint8(value and 255))
  snes.bus.write8(Wram + address.uint32 + 1, uint8(value shr 8))

proc word(snes: SnesBus, address: int): int =
  ## Read an original meter word from the isolated machine.
  snes.bus.read16(Wram + address.uint32).int

proc stepMeter(snes: SnesBus) =
  ## Invoke original $C2109F with native registers and a WRAM caller.
  var state = Cpu(pbr: 0x7E, pc: Caller.uint16, dbr: 0x7E,
    s: 0x1FFF, d: 0x0200)
  var steps = 0
  while state.pbr != 0x7E or state.pc != (Caller + 4).uint16:
    doAssert steps < StepLimit, "Original meter routine did not return"
    state.step(snes.bus)
    inc steps

proc checkCase(rom: seq[uint8], id, hp, hpTarget, pp, ppTarget: int) =
  ## Compare companion readings with original rolling arithmetic on generated state.
  let
    machine = newSnesBus(rom)
    base = PartyCharTableWram + (id - 1) * CharStride
    code = assembleAsm(".a16\n.i16\nJSL $C2109F\n", Caller)
  for index, value in code:
    machine.bus.write8(Wram + Caller + index.uint32, value)
  machine.bus.write8(Wram + BattleDisplayRoster, id.uint8)
  machine.bus.write8(Wram + PartyCountWram, 1)
  machine.bus.write8(Wram + base.uint32, uint8(ord('A') + 0x30))
  machine.bus.write8(Wram + (base + CharLevelOff).uint32, 1)
  machine.putWord(FastMeters, 1)
  machine.putWord(base + CharHpDisplayOff, hp)
  machine.putWord(base + CharHpCurOff, hpTarget)
  machine.putWord(base + CharHpMaxOff, 1000)
  machine.putWord(base + CharPpDisplayOff, pp)
  machine.putWord(base + CharPpCurOff, ppTarget)
  machine.putWord(base + CharPpMaxOff, 1000)
  # The original gate tests bit zero of each fixed-point fractional word.
  machine.putWord(base + HpFraction, 1)
  machine.putWord(base + PpFraction, 1)
  var
    names: array[256, string]
    previousHp = hp
    previousPp = pp
    iterations = 0
  while previousHp != hpTarget or previousPp != ppTarget:
    doAssert iterations < 100, "Original meter did not converge"
    machine.stepMeter()
    let
      currentHp = machine.word(base + CharHpDisplayOff)
      currentPp = machine.word(base + CharPpDisplayOff)
      party = readDsParty(machine.bus.mem.toOpenArray(Wram.int, Wram.int + 0x1FFFF), names, true)
    doAssert party.len == 1
    doAssert party[0].id == id
    doAssert party[0].hp == currentHp and party[0].pp == currentPp
    doAssert currentHp in min(hp, hpTarget) .. max(hp, hpTarget)
    doAssert currentPp in min(pp, ppTarget) .. max(pp, ppTarget)
    doAssert currentHp != previousHp or currentPp != previousPp, "Meter stalled"
    previousHp = currentHp
    previousPp = currentPp
    inc iterations
  doAssert iterations > 1, "Meter jumped directly to its target"
  let settled = readDsParty(machine.bus.mem.toOpenArray(Wram.int, Wram.int + 0x1FFFF), names)
  doAssert settled[0].hp == hpTarget and settled[0].pp == ppTarget

proc main() =
  ## Verify original HP/PP damage, healing, spending, recovery and mortal convergence.
  let rom = readGoldBaserom()
  for id in 1 .. PlayableCharCount:
    for values in [(300, 100, 12, 12), (100, 300, 12, 12),
        (100, 100, 30, 2), (100, 100, 2, 30), (30, 0, 12, 12)]:
      checkCase(rom, id, values[0], values[1], values[2], values[3])

  block rosterOrder:
    let
      machine = newSnesBus(rom)
      order = [3, 2, 4, 1]
      code = assembleAsm(".a16\n.i16\nJSL $C2109F\n", Caller)
    for index, value in code:
      machine.bus.write8(Wram + Caller + index.uint32, value)
    for index, id in order:
      let base = PartyCharTableWram + (id - 1) * CharStride
      machine.bus.write8(Wram + BattleDisplayRoster + index.uint32, id.uint8)
      machine.bus.write8(Wram + base.uint32, uint8(ord('A') + id + 0x30))
      machine.bus.write8(Wram + (base + CharLevelOff).uint32, 1)
      machine.putWord(base + CharHpDisplayOff, 10)
      machine.putWord(base + CharHpCurOff, 50)
      machine.putWord(base + HpFraction, 1)
    machine.putWord(FastMeters, 1)
    machine.bus.write8(Wram + 0x98A4, 4)
    var names: array[256, string]
    let party = readDsParty(machine.bus.mem.toOpenArray(Wram.int, Wram.int + 0x1FFFF), names, true)
    doAssert party.len == 4
    for slot in 0 ..< order.len:
      machine.bus.write8(Wram + 2, slot.uint8)
      let id = party[slot].id
      let base = PartyCharTableWram + (id - 1) * CharStride
      let before = machine.word(base + CharHpDisplayOff)
      machine.stepMeter()
      doAssert machine.word(base + CharHpDisplayOff) > before,
        "Companion order differs from the character selected by original $C2109F"

  if paramCount() == 2:
    let
      machine = newSnesBus(rom)
      snapshot = extractStateForRom(cast[seq[uint8]](readFile(paramStr(1))), romHashOf(rom))
    var state: Cpu
    deserializeState(snapshot, machine, state)
    var actual, expected: seq[int]
    var names: array[256, string]
    for member in readDsParty(machine.bus.mem.toOpenArray(Wram.int, Wram.int + 0x1FFFF), names):
      actual.add(member.id)
    for id in paramStr(2).split(','): expected.add(parseInt(id))
    doAssert actual == expected, "Screenstate party differs: " & $actual & " versus " & $expected
    let
      live = readPartyVitalsFromWram(machine)
      persisted = readPartyVitalsFromBytes(persistBlockToSramBytes(machine))
    for index, role in CharRoleNames:
      let active = index + 1 in expected
      for member in live.members:
        if member.role == role: doAssert member.inParty == active
      for member in persisted.members:
        if member.role == role: doAssert member.inParty == active

main()
