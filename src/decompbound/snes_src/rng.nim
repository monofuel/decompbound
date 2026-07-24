## EarthBound's pseudo-random number generator (file 0x008E9A / SNES $C08E9A).
##
## The SNES has no hardware entropy, so "randomness" is this deterministic PRNG
## over a 32-bit seed in WRAM. Same seed + same call count => same sequence, which
## is why a fixed save-state replays byte-identically (verified: seed at $0024
## reproduced across runs). RE'd 2026-07-21 (dynamic trace + round-trip).
##
## Documentation of the understood routine, expressed through `snesAsm` so it
## reads as annotated assembly. ADOPTED into the region registry (adopted.nim):
## convert_all carves these 56 bytes out of the enclosing traced region
## (0x008C6D-0x008F97), so this curated source — not generated scaffold —
## produces $C08E9A in the build. Gold-gated two ways: tests/test_regions.nim
## (byte-exact vs gold, un-fakeable) and tests/test_rng.nim (routine fully
## covered by one region). This is the first mid-region Goal 1.5 adoption.

import
  ../snes_asm

const
  RngAdvanceOffset* = 0x008E9A
  RngAdvanceSnes* = 0xC08E9A'u32
  ## 32-bit RNG seed in WRAM, little-endian: lo word $0024, hi word $0026.
  ## Cold-initialised to $5678_1234 at $C08121 (LDA #$1234;STA $0024;
  ## LDA #$5678;STA $0026) — the fixed seed that makes cold boot deterministic.
  RngSeedLo* = 0x0024'u32
  RngSeedHi* = 0x0026'u32
  ## $4202 = WRMPYA/WRMPYB (an unsigned 8x8 multiply input pair); a 16-bit STA
  ## loads both. Product reads back at $4216 (RDMPYL/H) a few cycles later.
  MultiplyInput* = 0x004202'u32
  MultiplyResult* = 0x004216'u32
  ## Odd additive constant folded into the high word each step (LCG-like stir).
  RngStepConstant* = 0x006D'u32
  ## Low two bits of the rotated product mix into the low word; if the final
  ## ROR sets carry, the high bit is forced (keeps the low word from decaying).
  RngLowMix* = 0x0003'u32
  RngHighBit* = 0x8000'u32
  ReturnByteMask* = 0x00FF'u32
  StatusM* = 0x20'u32

proc earthboundRandom*(): seq[uint8] =
  ## Advance the RNG one step; returns a random byte 0..255 in A.
  ##
  ## Mixes the seed via the hardware multiplier: seed_hi.lo * seed_lo.lo, folds
  ## +$6D into seed_hi, rotates the product into seed_lo (with a carry-driven
  ## high-bit set), and returns the rotated product byte. Reimplementation
  ## matched the live emulator 10/10 advances (seed + return byte).
  ##
  ## Entry: any flags (saves via PHP, manages M itself). Called via JSL only
  ## (59 sites); e.g. $C2008C gates a battle roll, $C02686 branches ~1/16.
  snesAsm(RngAdvanceSnes, NativeFlags16):
    php
    rep StatusM
    lda abs RngSeedLo         # seed_lo -> A (16-bit)
    sep StatusM
    xba                       # stash seed_lo.lo in B
    lda abs RngSeedHi         # seed_hi.lo -> A (8-bit)
    rep StatusM
    sta long MultiplyInput    # WRMPYA = seed_hi.lo, WRMPYB = seed_lo.lo
    clc
    adc RngStepConstant       # seed_hi += $6D
    sta abs RngSeedHi
    lda long MultiplyResult   # 16-bit product
    ror a
    ror a
    pha
    andOp RngLowMix           # product bits 1..0
    clc
    adc abs RngSeedLo
    ror a
    bcc "seedLoStore"
    ora RngHighBit            # carry set -> force high bit
    label "seedLoStore"
    sta abs RngSeedLo         # new seed_lo
    pla
    ror a
    ror a
    andOp ReturnByteMask      # return byte in A
    plp
    rtl
