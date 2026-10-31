import
  decompbound/snesbus,
  ./original_cpu

const
  EffectCount* = 4
  EffectPointers* = [0x301E, 0x30D2, 0x2F6A, 0x2EB6]
  EffectTimers* = [0x305A, 0x310E, 0x2FA6, 0x2EF2]
  EffectOutputs* = [0x3096, 0x314A, 0x2FE2, 0x2F2E]
  EffectScriptBase* = 0xE000
  EffectDefinitionBase* = 0xF000
  EffectSpacing* = 0x20
  EffectBank* = 0xC4
  EffectBankFile = 0x040000

proc scriptPointer*(lane: int): int =
  ## Locate an authored sequence in the private test cartridge image.
  EffectScriptBase + lane * EffectSpacing

proc definitionPointer*(lane, phase = 0): int =
  ## Locate an authored one-record definition for a timer phase.
  EffectDefinitionBase + lane * EffectSpacing + phase * 0x10

proc syntheticEffectsImage*(image: seq[uint8]): seq[uint8] =
  ## Replace private C4 test regions with authored sequences and definitions only in memory.
  result = newSeq[uint8](image.len)
  for index, value in image:
    result[index] = value
  for lane in 0 ..< EffectCount:
    let
      start = scriptPointer(lane)
      definition = definitionPointer(lane)
      words = [1, definition, 0, 3, 1, definition + 0x10, 0, 2, 3, start]
    for index, value in words:
      result[EffectBankFile + start + index * 2] = (value and 255).uint8
      result[EffectBankFile + start + index * 2 + 1] = (value shr 8).uint8
    for phase in 0 .. 1:
      for variant in 0 .. 2:
        let
          base = EffectBankFile + definitionPointer(lane, phase) + variant * 5
          record = [0'u8, (0x40 + lane * 8 + phase * 3 + variant).uint8,
            0xA5'u8, 0'u8, 0x80'u8]
        for index, value in record:
          result[base + index] = value

proc seedEffects*(snes: SnesBus, entity: int, timer = 0) =
  ## Install four independent synthetic pointer/timer/output lanes for an entity.
  for lane in 0 ..< EffectCount:
    snes.putWord(EffectPointers[lane] + entity * 2, scriptPointer(lane))
    snes.putWord(EffectTimers[lane] + entity * 2, timer)
    snes.putWord(EffectOutputs[lane] + entity * 2, definitionPointer(lane))

proc selectedEffects*(entity, flags, status, size: int): seq[int] =
  ## Specify the independently expected enqueue order for the helper's four lanes.
  let mode = flags and 12
  if mode in [8, 12]:
    result.add(if size == 0x40: 0 else: 1)
  if entity >= 23:
    if mode == 4 or (status and 0x8000) != 0:
      result.add 2
    if (status and 0x4000) != 0:
      result.add 3
