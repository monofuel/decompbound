## Pure-Nim arithmetic mirror of EarthBound's PRNG advance at $C08E9A.
##
## `snes_src/rng.nim` is the adopted byte-exact snesAsm routine. This module
## exports the same step as a pure function over a 32-bit seed so Layer 2 can
## scan drop windows without spinning the emulator. Verified against live
## emulator calls in tests/test_rng_oracle.nim (50+ pre/post seed + return byte).

const
  ## Odd additive constant folded into the high word each step (matches RngStepConstant).
  RngStepConstant = 0x006D'u16
  ## Low two bits of the rotated product mix into seed_lo.
  RngLowMix = 0x0003'u16
  ## Forced into seed_lo when the post-mix ROR leaves carry set.
  RngHighBit = 0x8000'u16

proc ror16(value: uint16, carryIn: bool): tuple[value: uint16, carry: bool] =
  ## 16-bit rotate-right through carry (65816 ROR A in M=0).
  let
    newCarry = (value and 1'u16) != 0
    carryBit = if carryIn: 0x8000'u16 else: 0'u16
  (value: (value shr 1) or carryBit, carry: newCarry)

proc advanceSeed*(seed: uint32): tuple[value: uint8, seed: uint32] =
  ## Advance the EarthBound PRNG one step.
  ##
  ## Mirrors $C08E9A exactly: 8x8 HW mul of seed_hi.lo * seed_lo.lo, fold +$6D
  ## into a 16-bit reconstruction of (seed_lo.lo << 8 | seed_hi.lo) written back
  ## as seed_hi, double-ROR the product (carry in from that ADC), mix product
  ## bits 1..0 into seed_lo with a carry-forced high bit, return the low byte of
  ## a further double-ROR of the rotated product (carry in from the seed_lo ROR).
  let
    oldLo = uint16(seed and 0xFFFF'u32)
    oldHi = uint16(seed shr 16)
    loLo = uint8(oldLo and 0xFF'u16)
    hiLo = uint8(oldHi and 0xFF'u16)
    product = uint16(hiLo.uint16 * loLo.uint16)
  # CLC; ADC #$006D on A = (seed_lo.lo << 8) | seed_hi.lo → STA seed_hi.
  let
    hiTmp = uint32((uint16(loLo) shl 8) or uint16(hiLo)) + uint32(RngStepConstant)
    newHi = uint16(hiTmp and 0xFFFF'u32)
    carryFromHi = hiTmp > 0xFFFF'u32
  # LDA product; ROR; ROR (carry from the seed_hi ADC).
  var
    a = product
    c = carryFromHi
  (a, c) = ror16(a, c)
  (a, c) = ror16(a, c)
  let rotated = a
  # AND #$0003; CLC; ADC seed_lo; ROR; BCC skip; ORA #$8000; STA seed_lo.
  let
    mix = rotated and RngLowMix
    sum = uint32(mix) + uint32(oldLo)
    sum16 = uint16(sum and 0xFFFF'u32)
    carryFromSum = sum > 0xFFFF'u32
  (a, c) = ror16(sum16, carryFromSum)
  if c:
    a = a or RngHighBit
  let
    newLo = a
    # Carry into the return-byte path is still the post-ROR carry from sum
    # (BCC/ORA/STA do not clear it): equal to bit0 of sum16.
    carryToReturn = (sum16 and 1'u16) != 0
  a = rotated
  c = carryToReturn
  (a, c) = ror16(a, c)
  (a, c) = ror16(a, c)
  let value = uint8(a and 0xFF'u16)
  let newSeed = (uint32(newHi) shl 16) or uint32(newLo)
  (value: value, seed: newSeed)

proc seedFromWords*(lo, hi: uint16): uint32 =
  ## Pack WRAM seed words ($0024 lo, $0026 hi) into a 32-bit LE seed.
  uint32(lo) or (uint32(hi) shl 16)

proc seedLo*(seed: uint32): uint16 =
  ## Low word of the 32-bit seed (WRAM $0024).
  uint16(seed and 0xFFFF'u32)

proc seedHi*(seed: uint32): uint16 =
  ## High word of the 32-bit seed (WRAM $0026).
  uint16(seed shr 16)
