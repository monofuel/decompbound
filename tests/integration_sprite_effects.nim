import
  std/strformat,
  decompbound/[cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom, sprite_effect_fixture]

const
  EntityCount = 30
  QueueBase = 0x2404
  QueueSpacing = 0x102
  ScreenX = 80
  ScreenY = 96
  Guard = 0x5AA5
  SequenceScratchBase = 0xE800
  SequenceOutput = 0x3200
  EffectBusBase = EffectBank shl 16
  EffectStatuses = [0, 1, 0x4000, 0x8000, 0xC000, 0xFFFF]

proc checkSequence(snes: SnesBus, entity, command, duration: int, redirect: bool) =
  ## Check command interpretation and returned pointer/delay with entirely authored words.
  let
    target = SequenceScratchBase + 0x40
    start = SequenceScratchBase
    output = SequenceOutput + entity * 2
    outputValue = 0x4567 + entity
    words = if redirect: @[1, 0x1111, 3, target] else:
      @[1, 0x1111, 1, outputValue, command, duration]
  for index, value in words:
    snes.bus.mem[EffectBusBase + start + index * 2] = (value and 255).uint8
    snes.bus.mem[EffectBusBase + start + index * 2 + 1] = (value shr 8).uint8
  for index, value in [1, outputValue, command, duration]:
    snes.bus.mem[EffectBusBase + target + index * 2] = (value and 255).uint8
    snes.bus.mem[EffectBusBase + target + index * 2 + 1] = (value shr 8).uint8
  for slot in 0 ..< EntityCount:
    snes.putWord(SequenceOutput + slot * 2, Guard)
  snes.putWord(DirectPage.int + 0x88, entity * 2)
  snes.putWord(DirectPage.int + 2, start)
  snes.putWord(DirectPage.int + 4, EffectBank)
  let state = snes.call("JSR $AD56", a = SequenceOutput, status = FlagC)
  doAssert state.x.int == output and state.y.int == duration
  doAssert state.a.int == (if redirect: target + 8 else: start + 12)
  doAssert snes.word(DirectPage.int + 2) == (if redirect: target else: start)
  doAssert snes.word(DirectPage.int + 8) == (if redirect: 8 else: 12)
  doAssert snes.word(output) == outputValue
  for slot in 0 ..< EntityCount:
    if slot != entity:
      doAssert snes.word(SequenceOutput + slot * 2) == Guard

proc checkSequenceNoWrite(snes: SnesBus) =
  ## Check a delay-only sequence preserves its destination and wraps the returned low pointer.
  for index, value in [0, 0, 0xFF, 0xFF]:
    snes.bus.mem[EffectBusBase + 0xFFFC + index] = value.uint8
  snes.putWord(DirectPage.int + 0x88, 0)
  snes.putWord(DirectPage.int + 2, 0xFFFC)
  snes.putWord(DirectPage.int + 4, EffectBank)
  snes.putWord(SequenceOutput, Guard)
  let state = snes.call("JSR $AD56", a = SequenceOutput)
  doAssert state.a == 0 and state.y == 0xFFFF
  doAssert snes.word(SequenceOutput) == Guard
  doAssert snes.word(DirectPage.int + 4) == EffectBank

proc checkSequenceBankCarry(snes: SnesBus) =
  ## Distinguish linear long-indexed reads from the wrapped low-word return pointer.
  for index, value in [1, 0x7777, 0, 2]:
    let address = EffectBusBase + 0xFFFC + index * 2
    snes.bus.mem[address] = (value and 255).uint8
    snes.bus.mem[address + 1] = (value shr 8).uint8
  snes.putWord(DirectPage.int + 0x88, 0)
  snes.putWord(DirectPage.int + 2, 0xFFFC)
  snes.putWord(DirectPage.int + 4, EffectBank)
  let state = snes.call("JSR $AD56", a = SequenceOutput)
  doAssert state.a == 4 and state.y == 2
  doAssert snes.word(SequenceOutput) == 0x7777
  doAssert snes.word(DirectPage.int + 4) == EffectBank

proc checkEffectBranch(snes: SnesBus, entity, flags, status, size, group,
    initialTimer: int, zeroPrimary: bool) =
  ## Check every effect selector's state changes and exact queued records across seven ticks.
  let
    offset = entity * 2
    selected = selectedEffects(entity, flags, status, size)
  for lane in 0 ..< EffectCount:
    for slot in 0 ..< EntityCount:
      for field in [EffectPointers[lane], EffectTimers[lane], EffectOutputs[lane]]:
        snes.putWord(field + slot * 2, Guard)
  snes.seedEffects(entity, initialTimer)
  if zeroPrimary:
    snes.putWord(EffectOutputs[2] + offset, 0)
  snes.putWord(DirectPage.int + 0x88, offset)
  snes.putWord(0x2BAA + offset, flags)
  snes.putWord(0x2E7A + offset, status)
  snes.putWord(0x2A7E + offset, size)
  snes.putWord(0x0B16 + offset, ScreenX)
  snes.putWord(0x0B52 + offset, ScreenY)
  var
    timers: array[EffectCount, int]
    phases: array[EffectCount, int]
    nextPhases: array[EffectCount, int]
    pointers: array[EffectCount, int]
    outputs: array[EffectCount, int]
  for lane in 0 ..< EffectCount:
    timers[lane] = initialTimer
    pointers[lane] = scriptPointer(lane)
    outputs[lane] = if zeroPrimary and lane == 2: 0 else: definitionPointer(lane)
  for tick in 0 .. 6:
    snes.putWord(0x2E, 1)
    snes.call("JSL $C088B1")
    snes.putWord(0x2400, group)
    snes.call("JSL $C0AC43", x = offset)
    var emitted: seq[int]
    for lane in selected:
      if timers[lane] == 0:
        phases[lane] = nextPhases[lane]
        outputs[lane] = definitionPointer(lane, phases[lane])
        timers[lane] = if phases[lane] == 0: 3 else: 2
        pointers[lane] = scriptPointer(lane) + (if phases[lane] == 0: 8 else: 16)
        nextPhases[lane] = phases[lane] xor 1
      timers[lane] = (timers[lane] - 1) and 0xFFFF
      if lane != 2 or outputs[lane] != 0:
        emitted.add lane
    for lane in 0 ..< EffectCount:
      doAssert snes.word(EffectTimers[lane] + offset) == timers[lane],
        &"timer lane {lane}, entity {entity}, flags {flags}, status {status}, tick {tick}"
      doAssert snes.word(EffectPointers[lane] + offset) == pointers[lane]
      doAssert snes.word(EffectOutputs[lane] + offset) == outputs[lane]
      for slot in 0 ..< EntityCount:
        if slot != entity:
          for field in [EffectPointers[lane], EffectTimers[lane], EffectOutputs[lane]]:
            doAssert snes.word(field + slot * 2) == Guard
    for queue in 0 .. 3:
      let base = QueueBase + queue * QueueSpacing
      doAssert snes.word(base + 0x100) == (if queue == group: emitted.len * 2 else: 0)
    let base = QueueBase + group * QueueSpacing
    for index, lane in emitted:
      let
        variant = if (flags and 1) == 0: 0 else: (if lane == 1: 2 else: 1)
        pointer = outputs[lane] + variant * 5
        y = ScreenY + (if lane == 1: 8 else: 0)
      doAssert snes.word(base + index * 2) == pointer
      doAssert snes.word(base + 0x40 + index * 2) == ScreenX
      doAssert snes.word(base + 0x80 + index * 2) == y
      doAssert snes.word(base + 0xC0 + index * 2) == EffectBank
    snes.call("JSL $C08B26")
    doAssert snes.word(3) == 0x500 + emitted.len * 4
    for index, lane in emitted:
      let
        variant = if (flags and 1) == 0: 0 else: (if lane == 1: 2 else: 1)
        address = Wram + (0x500 + index * 4).uint32
        tile = 0x40 + lane * 8 + phases[lane] * 3 + variant
      doAssert snes.bus.read8(address) == ScreenX.uint8
      doAssert snes.bus.read8(address + 1) == (ScreenY - 1 + (if lane == 1: 8 else: 0)).uint8
      doAssert snes.bus.read8(address + 2) == tile.uint8
      doAssert snes.bus.read8(address + 3) == 0xA5

proc checkZeroDuration(snes: SnesBus) =
  ## Show that a zero delay underflows to FFFF rather than advancing again immediately.
  let start = scriptPointer(0)
  snes.bus.mem[EffectBusBase + start + 6] = 0
  snes.bus.mem[EffectBusBase + start + 7] = 0
  snes.seedEffects(0)
  snes.putWord(DirectPage.int + 0x88, 0)
  snes.putWord(0x2BAA, 8)
  snes.putWord(0x2E7A, 0)
  snes.putWord(0x2A7E, 0x40)
  snes.putWord(0x2400, 0)
  for tick in 0 .. 1:
    snes.putWord(0x2504, 0)
    snes.call("JSL $C0AC43", x = 0)
    doAssert snes.word(EffectTimers[0]) == 0xFFFF - tick
    doAssert snes.word(EffectPointers[0]) == start + 8
  snes.bus.mem[EffectBusBase + start + 6] = 3

proc checkEffectPointerCarry(snes: SnesBus) =
  ## Preserve the other-size lane's carry between its two definition-addend ADCs.
  const RecordAddend = 5
  snes.putWord(DirectPage.int + 0x88, 0)
  snes.putWord(0x2BAA, 9)
  snes.putWord(0x2E7A, 0)
  snes.putWord(0x2A7E, 0x20)
  snes.putWord(0x2400, 0)
  for pointer in [0xFFF9, 0xFFFA, 0xFFFB, 0xFFFF]:
    snes.putWord(0x2504, 0)
    snes.putWord(EffectTimers[1], 1)
    snes.putWord(EffectOutputs[1], pointer)
    snes.call("JSL $C0AC43", x = 0)
    let
      first = pointer + RecordAddend
      carry = first div 0x10000
      expected = ((first and 0xFFFF) + RecordAddend + carry) and 0xFFFF
    doAssert snes.word(0x2404) == expected
    doAssert snes.word(0x24C4) == EffectBank and snes.word(0x2504) == 2

proc main() =
  ## Exercise original and rebuilt effect code with synthetic cartridge and WRAM data.
  var
    sequenceCases = 0
    branchCases = 0
  for image in engineImages("bin/sprite_effects_extract"):
    let snes = newSnesBus(syntheticEffectsImage(image))
    for entity in 0 ..< EntityCount:
      for command in [0, 2, 4, 0xFFFF]:
        for duration in [0, 1, 2, 0xFFFF]:
          for redirect in [false, true]:
            snes.checkSequence(entity, command, duration, redirect)
            inc sequenceCases
    snes.checkSequenceNoWrite()
    snes.checkSequenceBankCarry()
    for entity in [0, 5, 22, 23, 29]:
      for flags in 0 .. 15:
        for status in EffectStatuses:
          for size in [0x20, 0x40, 0x80]:
            for timer in [0, 1, 2]:
              snes.checkEffectBranch(entity, flags, status, size,
                (entity + flags) mod 4, timer, false)
              inc branchCases
    for status in [0x8000, 0xC000]:
      snes.checkEffectBranch(23, 0, status, 0x40, 3, 2, true)
      inc branchCases
    snes.checkZeroDuration()
    snes.checkEffectPointerCarry()
  echo &"sprite effects: {sequenceCases} sequence cases, {branchCases} seven-tick branch cases passed"

when isMainModule:
  main()
