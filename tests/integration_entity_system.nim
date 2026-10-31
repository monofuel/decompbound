import
  decompbound/[asm_parse, cpu, rom_pipeline, snesbus],
  ./engine/original_cpu

const
  EntityCount = 30
  StateCount = 70
  ActiveHead = 0x0A50
  FreeEntityHead = 0x0A52
  FreeStateHead = 0x0A54
  EntityLinks = 0x0A9E
  StateLinks = 0x125A
  ScriptIds = 0x0A62
  CallbackFlags = 0x10B6
  GraphicsBanks = 0x116A
  SuppressionMask = 0xC000
  Sentinel = 0x5A5A
  Entities = [0, 5, 29]
  FlagSamples = [0, 1, 0x7E, 0x1234, 0x3FFF, 0x4000, 0x8000, 0xFFFF]
  TemplateFields = [0x0A38, 0x0A3A, 0x0A3C, 0x0A3E, 0x0A40,
    0x0A42, 0x0A44, 0x0A46, 0x0A48, 0x0A4A]
  RenderCallback = 0x1D00
  RenderResult = 0x1800
  FrameIndices = [0, 1, 0x7FFF, 0x8000, 0xFFFF]
  BankStates = [0x007E, 0x407E, 0x807E, 0xFFFF]
  TilePool = 0x4A00
  TileSlots = 88
  DefinitionPool = 0x467E
  DefinitionBytes = 896
  SpawnResource = 437
  GraphicsOperands = 0x7F4000'u32

proc checkInitialization(snes: SnesBus) =
  ## Verify every pool link and the actual initialization footprint against dirty WRAM.
  for address in countup(0x0A38, 0x1A40, 2):
    snes.putWord(address, Sentinel)
  for address in 0x280B .. 0x2849:
    snes.bus.write8(Wram + address.uint32, 0x5A)
  snes.call("JSL $C09282")
  doAssert snes.word(ActiveHead) == 0xFFFF
  doAssert snes.word(FreeEntityHead) == 0 and snes.word(FreeStateHead) == 0
  for id in 0 ..< EntityCount:
    doAssert snes.word(EntityLinks + id * 2) ==
      (if id == EntityCount - 1: 0xFFFF else: (id + 1) * 2)
    doAssert snes.word(ScriptIds + id * 2) == 0xFFFF
    doAssert snes.word(CallbackFlags + id * 2) == 0
    doAssert snes.word(GraphicsBanks + id * 2) == 0
  for id in 0 ..< StateCount:
    doAssert snes.word(StateLinks + id * 2) ==
      (if id == StateCount - 1: 0xFFFF else: (id + 1) * 2)
  for base in [0x1A02, 0x1A0A, 0x1A12, 0x1A1A, 0x1A22, 0x1A2A, 0x1A32, 0x1A3A]:
    for index in 0 ..< 4:
      doAssert snes.word(base + index * 2) == 0
  for index in 0 ..< 4:
    doAssert snes.word(0x103E + index * 2) == 0
  doAssert snes.word(0x0A60) == 0
  doAssert snes.word(0x0A38) == Sentinel and snes.word(0x0A5E) == Sentinel
  doAssert snes.word(0x1168) == Sentinel
  doAssert snes.word(0x0AD8) == 0xFFFF and snes.word(0x12E4) == 0xFFFF
  for address in 0x280C .. 0x2848:
    doAssert snes.bus.read8(Wram + address.uint32) == 0
  doAssert snes.bus.read8(Wram + 0x280B) == 0x5A
  doAssert snes.bus.read8(Wram + 0x2849) == 0x5A

proc checkStateAllocation(snes: SnesBus) =
  ## Exhaust all script-state slots, including the empty-list return without memory writes.
  for id in 0 ..< StateCount:
    let state = snes.call("JSR $9D03", a = Sentinel)
    doAssert state.y.int == id * 2 and (state.p and FlagC) == 0
    doAssert snes.word(FreeStateHead) ==
      (if id == StateCount - 1: 0xFFFF else: (id + 1) * 2)
  let state = snes.call("JSR $9D03", a = Sentinel)
  doAssert state.y == 0xFFFF and state.a == Sentinel and (state.p and FlagC) != 0
  doAssert snes.word(FreeStateHead) == 0xFFFF

proc checkPause(snes: SnesBus) =
  ## Check both high-bit controls and unchanged inactive entities across linked-list orders.
  for sample in FlagSamples:
    for reverse in [false, true]:
      snes.putWord(ActiveHead, (if reverse: Entities[^1] else: Entities[0]) * 2)
      for id in 0 ..< EntityCount:
        snes.putWord(CallbackFlags + id * 2, sample)
      for index, id in Entities:
        let next = if reverse:
          (if index == 0: 0xFFFF else: Entities[index - 1] * 2)
        else:
          (if index == Entities.high: 0xFFFF else: Entities[index + 1] * 2)
        snes.putWord(EntityLinks + id * 2, next)
      snes.call("JSL $C0943C")
      for id in 0 ..< EntityCount:
        doAssert snes.word(CallbackFlags + id * 2) ==
          (if id in Entities: sample or SuppressionMask else: sample)
      snes.call("JSL $C09451")
      for id in 0 ..< EntityCount:
        doAssert snes.word(CallbackFlags + id * 2) ==
          (if id in Entities: sample and not SuppressionMask else: sample)
  snes.putWord(ActiveHead, 0xFFFF)
  snes.putWord(CallbackFlags, Sentinel)
  snes.call("JSL $C0943C")
  snes.call("JSL $C09451")
  doAssert snes.word(CallbackFlags) == Sentinel

proc checkDefaultConstructor(snes: SnesBus) =
  ## Verify the convenience entry clears its templates and restores ID-unit bounds before construction.
  snes.call("JSL $C09282")
  for address in TemplateFields:
    snes.putWord(address, Sentinel)
  snes.putWord(0x0A4C, 29)
  snes.putWord(0x0A4E, 29)
  let state = snes.call("JSL $C092F5", a = 7, x = 123, y = 456)
  doAssert state.a == 0 and (state.p and FlagC) == 0
  for address in TemplateFields:
    doAssert snes.word(address) == 0
  doAssert snes.word(0x0A4C) == 0 and snes.word(0x0A4E) == EntityCount * 2
  doAssert snes.word(ScriptIds) == 7
  doAssert snes.word(0x0B8E) == 123 and snes.word(0x0BCA) == 456
  doAssert snes.word(ActiveHead) == 0 and snes.word(FreeEntityHead) == 2

proc checkGraphicsDispatch(snes: SnesBus) =
  ## Distinguish inherited overflow from bank-state bit 14 and cover each rejected dispatch.
  let code = assembleAsm(".a16\n.i16\nSTA $1800\nSTX $1802\nINC $1804\nRTS\n",
    RenderCallback.uint32)
  snes.putBytes(RenderCallback.uint32, code)
  for entity in Entities:
    let offset = entity * 2
    for bank in BankStates:
      for frame in FrameIndices:
        for overflow in [false, true]:
          snes.putWord(GraphicsBanks + offset, bank)
          snes.putWord(0x112E + offset, 0x4567)
          snes.putWord(0x10F2 + offset, frame)
          snes.putWord(0x11E2 + offset, RenderCallback)
          snes.putWord(DirectPage.int + 0x8C, Sentinel)
          snes.putWord(DirectPage.int + 0x8E, Sentinel)
          snes.putWord(RenderResult, Sentinel)
          snes.putWord(RenderResult + 2, Sentinel)
          snes.putWord(RenderResult + 4, 0)
          snes.call("JSR $A0E3", x = offset,
            status = (if overflow: FlagV else: 0'u8))
          let acceptedBank = bank < 0x8000 and not overflow
          doAssert snes.word(DirectPage.int + 0x8C) ==
            (if acceptedBank: 0x4567 else: Sentinel)
          doAssert snes.word(DirectPage.int + 0x8E) ==
            (if acceptedBank: bank else: Sentinel)
          let invokesCallback = acceptedBank and frame < 0x8000
          doAssert snes.word(RenderResult + 4) == (if invokesCallback: 1 else: 0)
          doAssert snes.word(RenderResult) == (if invokesCallback: frame else: Sentinel)
          doAssert snes.word(RenderResult + 2) == (if invokesCallback: offset else: Sentinel)

proc checkGraphicsPointer(snes: SnesBus) =
  ## Verify the handler's byte-wide bank write and retained accumulator high byte.
  for entity in Entities:
    for address in [0, 0x1234, 0xFFFF]:
      for bank in [0, 0x7E, 0xFF]:
        snes.putBytes(GraphicsOperands,
          [(address and 255).uint8, (address shr 8).uint8, bank.uint8])
        snes.putWord(DirectPage.int + 0x80, (GraphicsOperands and 0xFFFF).int)
        snes.putWord(DirectPage.int + 0x82, (GraphicsOperands shr 16).int)
        snes.putWord(DirectPage.int + 0x88, entity * 2)
        snes.putWord(GraphicsBanks + entity * 2, 0xAB00)
        let state = snes.call("JSR $9B4D")
        doAssert snes.word(0x112E + entity * 2) == address
        doAssert snes.word(GraphicsBanks + entity * 2) == (0xAB00 or bank)
        doAssert state.a.int == ((address and 0xFF00) or bank)
        doAssert state.x.int == entity * 2 and state.y == 3
        doAssert (state.p and (FlagM or FlagX)) == 0

proc checkScriptReplacement(snes: SnesBus, image: seq[uint8]) =
  ## Exercise every constructor-tail entry with returned state chains and explicit pointer-bank masking.
  for entity in Entities:
    for chainLength in [1, 2, StateCount]:
      for entry in [0x93B9, 0x93F9, 0x9403]:
        snes.call("JSL $C09282")
        snes.putWord(0x0A4C, entity)
        snes.putWord(0x0A4E, entity + 1)
        snes.call("JSL $C09321", a = 0, x = 123, y = 456)
        let offset = entity * 2
        snes.putWord(0x0ADA + offset, 0)
        for id in 0 ..< StateCount:
          snes.putWord(StateLinks + id * 2,
            if id == chainLength - 1 or id == StateCount - 1: 0xFFFF else: (id + 1) * 2)
        snes.putWord(FreeStateHead, if chainLength == StateCount: 0xFFFF else: chainLength * 2)
        snes.putWord(0x10F2 + offset, Sentinel)
        snes.putWord(0x0DAA + offset, Sentinel)
        snes.putWord(0x107A + offset, Sentinel)
        snes.putWord(CallbackFlags + offset, Sentinel)
        snes.putWord(0x1372, Sentinel)
        snes.putWord(0x12E6, Sentinel)
        let state = case entry
          of 0x93B9: snes.call("JSL $C093B9", a = 7, x = offset)
          of 0x93F9: snes.call("JSL $C093F9", a = 0x4567, x = entity, y = 0xAB7F)
          else: snes.call("JSL $C09403", a = 0x4567, x = offset, y = 0xAB7F)
        doAssert state.a.int == entity and (state.p and FlagC) == 0
        doAssert state.x == 0 and state.y.int == offset
        doAssert snes.word(0x0ADA + offset) == 0 and snes.word(StateLinks) == 0xFFFF
        doAssert snes.word(FreeStateHead) == 2
        for id in 1 ..< StateCount:
          doAssert snes.word(StateLinks + id * 2) ==
            (if id == StateCount - 1: 0xFFFF else: (id + 1) * 2)
        doAssert snes.word(0x1372) == 0 and snes.word(0x12E6) == 0
        doAssert snes.word(0x107A + offset) == 0x943B
        doAssert snes.word(CallbackFlags + offset) == 0xC0
        if entry == 0x93B9:
          let pointer = 0x400D4 + 7 * 3
          doAssert snes.word(ScriptIds + offset) == 7
          doAssert snes.word(0x13FE) == image[pointer].int + (image[pointer + 1].int shl 8)
          doAssert snes.word(0x148A) == image[pointer + 2].int
          doAssert snes.word(0x10F2 + offset) == 0xFFFF and snes.word(0x0DAA + offset) == 0
        else:
          doAssert snes.word(ScriptIds + offset) == 0
          doAssert snes.word(0x13FE) == 0x4567 and snes.word(0x148A) == 0x7F
          doAssert snes.word(0x10F2 + offset) == Sentinel
          doAssert snes.word(0x0DAA + offset) == Sentinel

proc checkSpawnWaits(image: seq[uint8]) =
  ## Observe the original failure loops without requiring an exhausted spawn to return.
  for tileExhausted in [false, true]:
    let snes = newSnesBus(image)
    snes.call("JSL $C09282")
    snes.call("JSL $C01A86")
    snes.call("JSL $C01C11", a = 0x8000)
    snes.bus.write8(Wram + 0x0D, 0x80)
    if tileExhausted:
      for index in 0 ..< TileSlots:
        snes.bus.write8(Wram + (TilePool + index).uint32, 0x80)
    else:
      for index in 0 ..< DefinitionBytes:
        snes.bus.write8(Wram + (DefinitionPool + index).uint32, 0)
    let code = assembleAsm(".a16\n.i16\nJSL $C01E49\n", Caller)
    snes.putBytes(Caller, code)
    var state = Cpu(pc: Caller.uint16, s: StackTop, d: DirectPage,
      dbr: 0x7E, a: SpawnResource, y: 0xFFFF)
    let spin = if tileExhausted: 0x1EB5'u16 else: 0x1EEF'u16
    snes.runUntil(state, 0xC0, spin)
    for iteration in 0 ..< 8:
      for instruction in 0 ..< 4:
        state.step(snes.bus)
      doAssert state.pbr == 0xC0 and state.pc == spin
      doAssert state.a > 0x7FFF
    doAssert snes.word(ActiveHead) == 0xFFFF
    doAssert snes.word(FreeEntityHead) == 0 and snes.word(FreeStateHead) == 0

proc checkSentinelResourceGate(image: seq[uint8]) =
  ## Verify the early return for resource $FFFF under $436C, then a valid resource under that gate.
  let snes = newSnesBus(image)
  snes.call("JSL $C09282")
  snes.call("JSL $C01A86")
  snes.call("JSL $C01C11", a = 0x8000)
  snes.bus.write8(Wram + 0x0D, 0x80)
  snes.putWord(0x436C, 1)
  let state = snes.call("JSL $C01E49", a = 0xFFFF, y = 0xFFFF)
  doAssert state.a == 0
  doAssert snes.word(ActiveHead) == 0xFFFF
  doAssert snes.word(FreeEntityHead) == 0 and snes.word(FreeStateHead) == 0
  for index in 0 ..< TileSlots:
    doAssert snes.bus.read8(Wram + (TilePool + index).uint32) == 0
  for index in 0 ..< DefinitionBytes:
    doAssert snes.bus.read8(Wram + (DefinitionPool + index).uint32) == 0xFF
  let explicit = snes.call("JSL $C01E49", a = SpawnResource, y = 5)
  doAssert explicit.a == 5 and snes.word(ActiveHead) == 10

proc main() =
  ## Exercise initialization and lifecycle helpers directly against the user's ROM.
  let
    image = readGoldBaserom()
    snes = newSnesBus(image)
  snes.checkInitialization()
  snes.checkStateAllocation()
  snes.checkPause()
  snes.checkDefaultConstructor()
  snes.checkGraphicsDispatch()
  snes.checkGraphicsPointer()
  snes.checkScriptReplacement(image)
  image.checkSpawnWaits()
  image.checkSentinelResourceGate()

when isMainModule:
  main()
