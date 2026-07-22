## CPU hardware multiply — WRMPYA / WRMPYB / RDMPY
## (file 0x008FF7 / SNES $C08FF7).
##
## Extremely hot JSL helper (hundreds of call sites) that multiplies the 16-bit
## value in A by the 8-bit value in Y using the S-CPU multiply unit at
## `$4202`/`$4203`/`$4216`. ADOPTED into the region registry (adopted.nim);
## gold-gated by tests/test_regions.nim.

import
  ./snes_asm

const
  HardwareMultiplyOffset* = 0x008FF7
  HardwareMultiplySnes* = 0xC08FF7'u32
  ## CPU MMIO: WRMPYA — 8-bit multiplicand (also first write of a 16-bit STA).
  WrmpyaReg* = 0x004202'u32
  ## CPU MMIO: WRMPYB — 8-bit multiplier; writing starts the multiply.
  WrmpybReg* = 0x004203'u32
  ## CPU MMIO: RDMPYL — 16-bit product low word (RDMPYL+RDMPYH).
  RdmpyReg* = 0x004216'u32
  ## Keep only the high byte of a 16-bit partial product when assembling the
  ## 16×8 result (XBA / AND #$FF00).
  HighByteMask* = 0xFF00'u32
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
  ## camera). Sibling `$C09032` is a wider 16×16 path and is not adopted here.
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
