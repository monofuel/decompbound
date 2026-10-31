import
  std/strformat,
  decompbound/[cpu, snesbus],
  ./engine/[original_cpu, rebuilt_rom]

const
  Positions = [0x0B8E, 0x0BCA, 0x0C06]
  Fractions = [0x0C42, 0x0C7E, 0x0CBA]
  IntegerSteps = [0x0CF6, 0x0D32, 0x0D6E]
  FractionSteps = [0x0DAA, 0x0DE6, 0x0E22]
  Integers = [0, 1, 0x7FFF, 0x8000, 0xFFFF]
  LowWords = [0, 0x7FFF, 0x8000, 0xFFFF]
  Steps = [0'u32, 1, 0xFFFF, 0x10000, 0xFFFF0000'u32, 0x7FFFFFFF,
    0x80000000'u32, 0xFFFFFFFF'u32]
  Guard = 0x5AA5
  EntityCount = 30
  MotionFields = [0x0B8E, 0x0BCA, 0x0C06, 0x0C42, 0x0C7E, 0x0CBA,
    0x0CF6, 0x0D32, 0x0D6E, 0x0DAA, 0x0DE6, 0x0E22]

proc checkMotion(snes: SnesBus, id, integer, fraction, stepIndex, axes: int) =
  ## Check modular 32-bit coordinate addition against a wider integer oracle.
  let offset = id * 2
  for field in MotionFields:
    for slot in 0 ..< EntityCount:
      snes.putWord(field + slot * 2, Guard)
  snes.putWord(DirectPage.int + 0x88, offset)
  var expected: array[3, uint64]
  for axis in 0 .. 2:
    let
      high = (integer + axis * 173) and 0xFFFF
      low = (fraction + axis * 31) and 0xFFFF
      delta = Steps[(stepIndex + axis) mod Steps.len]
      start = (high.uint64 shl 16) or low.uint64
    snes.putWord(Positions[axis] + offset, high)
    snes.putWord(Fractions[axis] + offset, low)
    snes.putWord(IntegerSteps[axis] + offset, (delta shr 16).int)
    snes.putWord(FractionSteps[axis] + offset, (delta and 0xFFFF).int)
    expected[axis] = (start + (if axis < axes: delta.uint64 else: 0'u64)) and
      0xFFFFFFFF'u64
  let state = snes.call(if axes == 2: "JSR $9FC8" else: "JSR $A00C",
    status = (if stepIndex mod 2 == 0: FlagC else: FlagV), y = 0x1234)
  doAssert state.x.int == offset and state.y == 0x1234
  doAssert (state.p and (FlagM or FlagX or FlagD)) == 0
  for axis in 0 .. 2:
    doAssert snes.word(Positions[axis] + offset) == (expected[axis] shr 16).int,
      &"entity {id}, axis {axis}, integer {integer}, fraction {fraction}, step {stepIndex}"
    doAssert snes.word(Fractions[axis] + offset) == (expected[axis] and 0xFFFF).int
    let delta = Steps[(stepIndex + axis) mod Steps.len]
    doAssert snes.word(IntegerSteps[axis] + offset) == (delta shr 16).int
    doAssert snes.word(FractionSteps[axis] + offset) == (delta and 0xFFFF).int
  for field in MotionFields:
    for slot in 0 ..< EntityCount:
      if slot != id:
        doAssert snes.word(field + slot * 2) == Guard

proc checkProjection(snes: SnesBus, id, worldX, worldY, origin, elevation: int) =
  ## Check each projection and rebasing entry against its coordinate equations.
  let offset = id * 2
  for entry in [0xA023, 0xA03A, 0xA055, 0xA06C, 0xA089, 0xA0A0, 0xA0BB]:
    for field in [0x0B8E, 0x0BCA, 0x0C06, 0x0B16, 0x0B52]:
      for slot in 0 ..< EntityCount:
        snes.putWord(field + slot * 2, Guard)
    snes.putWord(DirectPage.int + 0x88, offset)
    snes.putWord(0x0B8E + offset, worldX)
    snes.putWord(0x0BCA + offset, worldY)
    snes.putWord(0x0C06 + offset, elevation)
    snes.putWord(0x31, origin)
    snes.putWord(0x33, (origin + 7) and 0xFFFF)
    snes.putWord(0x39, (origin + 13) and 0xFFFF)
    snes.putWord(0x3B, (origin + 29) and 0xFFFF)
    let
      alternate = entry in [0xA055, 0xA06C, 0xA089, 0xA0A0]
      elevated = entry in [0xA03A, 0xA0A0]
      dx = if entry == 0xA0BB: 0 else: snes.word(if alternate: 0x39 else: 0x31)
      dy = if entry == 0xA0BB: 0 else: snes.word(if alternate: 0x3B else: 0x33)
      projectedX = (worldX - dx) and 0xFFFF
      projectedY = (worldY - dy - (if elevated: elevation else: 0)) and 0xFFFF
      longCall = entry in [0xA06C, 0xA089]
      instruction = if longCall: &"JSL $C0{entry:04X}" else: &"JSR ${entry:04X}"
    let state = snes.call(instruction, status = FlagC or FlagV, y = 0x1234)
    doAssert state.x.int == offset and state.y == 0x1234
    doAssert snes.word(0x0C06 + offset) == elevation
    if entry == 0xA089:
      doAssert snes.word(0x0B8E + offset) == ((worldX + dx) and 0xFFFF)
      doAssert snes.word(0x0BCA + offset) == ((worldY + dy) and 0xFFFF)
      doAssert snes.word(0x0B16 + offset) == Guard
      doAssert snes.word(0x0B52 + offset) == Guard
    else:
      doAssert snes.word(0x0B16 + offset) == projectedX
      doAssert snes.word(0x0B52 + offset) == projectedY
      doAssert snes.word(0x0B8E + offset) == (if entry == 0xA06C: projectedX else: worldX)
      doAssert snes.word(0x0BCA + offset) == (if entry == 0xA06C: projectedY else: worldY)
    for field in [0x0B8E, 0x0BCA, 0x0C06, 0x0B16, 0x0B52]:
      for slot in 0 ..< EntityCount:
        if slot != id:
          doAssert snes.word(field + slot * 2) == Guard

proc main() =
  ## Verify original and rebuilt callbacks using synthetic coordinates only.
  var calls = 0
  for image in engineImages("bin/entity_motion_extract"):
    let snes = newSnesBus(image)
    for id in 0 ..< EntityCount:
      for integer in Integers:
        for fraction in LowWords:
          for stepIndex in 0 ..< Steps.len:
            for axes in 2 .. 3:
              snes.checkMotion(id, integer, fraction, stepIndex, axes)
              inc calls
      for worldX in Integers:
        for worldY in Integers:
          for origin in [0, 0x8000, 0xFFFF]:
            for elevation in [0, 1, 0xFFFF]:
              snes.checkProjection(id, worldX, worldY, origin, elevation)
              calls += 7
  echo &"entity motion/projection: {calls} original/rebuilt calls passed"

when isMainModule:
  main()
