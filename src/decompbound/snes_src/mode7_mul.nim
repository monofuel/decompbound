## Mode-7 hardware multiply — M7A / M7B / MPYM
## (file 0x00B400 / SNES $C0B400).
##
## JSL-callable signed multiply that programs the PPU mode-7 multiply unit
## (M7A × M7B → 24-bit product at MPYL/MPYM/MPYH) using a ROM angle table for
## the second factor. ADOPTED into the region registry (adopted.nim);
## gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  Mode7MulBySineOffset* = 0x00B400
  Mode7MulBySineSnes* = 0xC0B400'u32
  ## PPU: M7A — mode-7 matrix A / hardware multiply multiplicand (write-twice).
  M7aReg* = 0x00211B'u32
  ## PPU: M7B — mode-7 matrix B / hardware multiply multiplier (write-once 8-bit).
  M7bReg* = 0x00211C'u32
  ## PPU: MPYM — middle byte of the 24-bit product; 16-bit LDA also takes MPYH
  ## at `$2136`, yielding the high 16 bits of M7A×M7B.
  MpymReg* = 0x002135'u32
  ## ROM sine/angle table indexed by (X − $40) & $FF. Data at `$C0B425`, not
  ## adopted — only referenced by address.
  Mode7AngleTable* = 0xC0B425'u32
  ## Angle-table origin: subtract before indexing so X=0 → table entry $C0.
  Mode7AngleOrigin* = 0x0040'u32
  ## Keep the adjusted angle in 0..255.
  ByteMask* = 0x00FF'u32
  StatusM* = 0x20'u32

proc mode7MulBySine*(): seq[uint8] =
  ## Multiply A by sin-table[X − $40] via the mode-7 hardware multiplier.
  ##
  ## Entry (JSL): 16-bit A holds the signed multiplicand written to M7A
  ## (write-twice: low then high via XBA). X is an angle index; the routine
  ## computes `(X − $40) & $FF`, loads an 8-bit factor from the table at
  ## `$C0B425,X`, and writes it to M7B. Returns the high 16 bits of the
  ## 24-bit product (`LDA long $2135` → MPYM+MPYH) in A with 16-bit M.
  ##
  ## Evidence (registers):
  ## - long `$211B` M7A — written twice (lo/hi of entry A).
  ## - long `$211C` M7B — one byte from `Mode7AngleTable`.
  ## - long `$2135` MPYM — 16-bit read of product mid/high.
  ##
  ## Callers: JSL `$C0B400` from bank `$C4` (e.g. `$C42662`, `$C4B084`).
  ## Does not touch M7C/M7D or mode-7 scroll — multiply unit only.
  snesAsm(Mode7MulBySineSnes, NativeFlags16):
    pha
    txa
    sec
    sbc Mode7AngleOrigin
    andOp ByteMask
    tax
    pla
    sep StatusM
    sta long M7aReg
    xba
    sta long M7aReg
    lda longx Mode7AngleTable
    sta long M7bReg
    rep StatusM
    lda long MpymReg
    rtl
