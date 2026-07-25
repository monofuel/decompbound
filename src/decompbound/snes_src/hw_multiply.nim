## CPU hardware multiply — WRMPYA / WRMPYB / RDMPY
## (file 0x008FF7 / SNES $C08FF7 and sibling $C09032).
##
## Hot JSL helpers that multiply via the S-CPU unit at `$4202`/`$4203`/`$4216`.
## `$C08FF7` is 16×8; `$C09032` is 16×16. ADOPTED into the region registry
## (adopted.nim); gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  HardwareMultiplyOffset* = 0x008FF7
  HardwareMultiplySnes* = 0xC08FF7'u32
  HardwareMultiply16Offset* = 0x009032
  HardwareMultiply16Snes* = 0xC09032'u32
  ## CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
  WrmpyaReg* = 0x004202'u32
  ## CPU MMIO: WRMPYB — 8-bit multiplier; writing starts the multiply.
  WrmpybReg* = 0x004203'u32
  ## CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
  RdmpyReg* = 0x004216'u32
  ## Keep only the high byte of a 16-bit partial product when assembling the
  ## 16×8 result (XBA / AND #$FF00).
  HighByteMask* = 0xFF00'u32
  ## 16×16 scratch: multiplier word saved at `$00B4`, multiplicand at `$00B6`,
  ## partial products / accumulators at `$00B0`..`$00B2`.
  Mul16FactorY* = 0x00B4'u32
  Mul16FactorA* = 0x00B6'u32
  Mul16ProductLo* = 0x00B0'u32
  Mul16ProductMid* = 0x00B1'u32
  Mul16ProductHi* = 0x00B2'u32
  ## Multiplier high byte address (second byte of `Mul16FactorY`).
  Mul16FactorYHi* = 0x00B5'u32
  ## Multiplicand low / high split reads during the three WRMPY steps.
  Mul16FactorALo* = 0x00B6'u32
  Mul16FactorAHiViaB4* = 0x00B4'u32
  ## Call counter bumped on every 16×16 entry (observed INC; role beyond
  ## counting is not yet pinned — do not invent a game-level name).
  # TODO: pin writer/readers of `$00C4` before promoting it in memory-map.md.
  Mul16CallCounter* = 0x00C4'u32
  StatusM* = 0x20'u32
  StatusX* = 0x10'u32

proc hardwareMultiply*(): seq[uint8] =
  ## Multiply 16-bit A by 8-bit Y via WRMPYA/WRMPYB; return 16-bit product in A.
  ##
  ## Entry (JSL): A is the 16-bit multiplicand, Y the 8-bit multiplier (low
  ## byte used). Forces 16-bit X (`REP #$10`). Two paths:
  ##
  ## 1. **A high ≠ 0** (`XBA` then fall through): compute `Y * A.hi` into Y
  ##    (partial), then `Y * A.lo` and add `(partial << 8)` — full 16×8.
  ## 2. **A high == 0** (branch to `mul8`): single `Y * A.lo` via WRMPY.
  ##
  ## Evidence (registers):
  ## - long `$4202` WRMPYA — written with the current 8-bit factor (via 16-bit
  ##   STA of Y or the low product path).
  ## - long `$4203` WRMPYB — written with A.hi on the wide path only.
  ## - long `$4216` RDMPY — 16-bit product read after each multiply.
  ##
  ## Timing: two NOPs after WRMPYA before reading RDMPY on each path (hardware
  ## needs 8 machine cycles; the surrounding ops cover the rest).
  ##
  ## Call sites: ~600 JSL `$C08FF7` across banks `$C0`/`$C1` (geometry, battle,
  ## camera). Sibling `hardwareMultiply16` at `$C09032` covers full 16×16.
  snesAsm(HardwareMultiplySnes, NativeFlags16):
    rep StatusX
    xba
    beq "mul8"
    sep StatusM
    xba
    pha
    tya
    rep StatusM
    sta long WrmpyaReg
    nop
    nop
    lda long RdmpyReg
    tay
    sep StatusM
    pla
    sta long WrmpybReg
    rep StatusM
    tya
    xba
    andOp HighByteMask
    clc
    adc long RdmpyReg
    rtl
    label "mul8"
    sep StatusM
    tya
    rep StatusM
    sta long WrmpyaReg
    nop
    nop
    lda long RdmpyReg
    rtl

proc hardwareMultiply16*(): seq[uint8] =
  ## Multiply 16-bit A by 16-bit Y via three WRMPY partial products.
  ##
  ## Entry (JSL): 16-bit A = multiplicand, 16-bit Y = multiplier. Saves Y at
  ## `$00B4` and A at `$00B6`, clears `$00B2`, bumps `$00C4`, then builds the
  ## product with three 8×8 hardware multiplies (16-bit `STA long $4202` writes
  ## WRMPYA+WRMPYB in one store; `LDA long $4216` reads RDMPY):
  ##
  ## 1. `Y.lo * Y.hi` path seeds `$00B0` from RDMPY (first partial).
  ## 2. `A.lo * Y.lo` folded into `$00B1` mid accumulator.
  ## 3. Final partial added into `$00B1`; returns `$00B0` in A.
  ##
  ## Evidence (registers / WRAM):
  ## - long `$4202` / `$4216` — WRMPY unit, three times.
  ## - abs `$00B4`/`$00B6` — saved factors; `$00B0`..`$00B2` product scratch.
  ## - abs `$00C4` — INC each call (counter only; not renamed further).
  ##
  ## Call sites: ~90 JSL `$C09032` (banks `$C0`/`$C2`/`$C3`/`$C4`/`$EF`); also
  ## re-entered from the adjacent `$C09086` DP-factor wrapper (not adopted).
  snesAsm(HardwareMultiply16Snes, NativeFlags16):
    sty abs Mul16FactorY
    sta abs Mul16FactorA
    stz abs Mul16ProductHi
    inc abs Mul16CallCounter
    lda abs Mul16FactorYHi
    sep StatusM
    tya
    rep StatusM
    sta long WrmpyaReg
    ldy abs Mul16FactorYHi
    rep StatusM
    lda long RdmpyReg
    sta abs Mul16ProductLo
    tya
    sta long WrmpyaReg
    lda abs Mul16FactorALo
    sep StatusM
    lda abs Mul16FactorAHiViaB4
    rep StatusM
    tay
    lda long RdmpyReg
    clc
    adc abs Mul16ProductMid
    sta abs Mul16ProductMid
    tya
    sta long WrmpyaReg
    nop
    lda abs Mul16ProductMid
    clc
    adc long RdmpyReg
    sta abs Mul16ProductMid
    lda abs Mul16ProductLo
    rtl
