## PPU window helpers — W*SEL / TMW / TSW / W*LOG / WH*
## (file 0x00B047 / SNES $C0B047 and $C0B0AA).
##
## JSL-callable writers that program the SNES window unit from packed fields
## in A/X, or force window edges to the disabled `$00FF` pattern. ADOPTED into
## the region registry (adopted.nim); gold-gated by tests/test_regions.nim.

import
  ./snes_asm

const
  ConfigurePpuWindowsOffset* = 0x00B047
  ConfigurePpuWindowsSnes* = 0xC0B047'u32
  ResetWindowPositionsOffset* = 0x00B0AA
  ResetWindowPositionsSnes* = 0xC0B0AA'u32
  ## PPU: W12SEL / W34SEL / WOBJSEL — which windows affect BG1-2 / BG3-4 / OBJ.
  W12SelReg* = 0x002123'u32
  W34SelReg* = 0x002124'u32
  WobjSelReg* = 0x002125'u32
  ## PPU: TMW / TSW — window mask enable for main / sub screens.
  TmwReg* = 0x00212E'u32
  TswReg* = 0x00212F'u32
  ## PPU: WBGLOG — 16-bit STA also covers WOBJLOG at $212B.
  WbgLogReg* = 0x00212A'u32
  ## PPU: WH0 — 16-bit STA also covers WH1 at $2127; WH2/WH3 via $2128.
  Wh0Reg* = 0x002126'u32
  Wh2Reg* = 0x002128'u32
  ## ROM nibble expand table: 2-bit field → W*SEL byte (00 / 0F / F0 / FF).
  ## Data at $C0B0A6, not adopted — only referenced by address.
  WindowSelExpandTable* = 0xC0B0A6'u32
  ## When X≠0 on entry, keep only the "window 2" bits of each expanded nibble.
  Window2OnlyMask* = 0xAA'u32
  ## Low 2 bits of each packed field in A.
  WindowFieldMask* = 0x03'u32
  ## Low 5 bits of the original A become the TMW/TSW layer mask.
  WindowMaskEnableBits* = 0x1F'u32
  ## WBGLOG/WOBJLOG = OR for every pair when windows are not inverted (X=0).
  WindowLogicOrAll* = 0x5555'u32
  ## WH0=FF WH1=00 WH2=FF WH3=00 — full-range / effectively-open edges.
  WindowEdgesOpen* = 0x00FF'u32
  StatusM* = 0x20'u32

proc configurePpuWindows*(): seq[uint8] =
  ## Program window selects, main/sub window masks, and window logic.
  ##
  ## Entry (JSL): 16-bit A/X. A packs three 2-bit window-select fields in the
  ## low 6 bits (BG1-2, BG3-4, OBJ) plus a 5-bit TMW/TSW enable mask in the
  ## low 5 bits of the original value (restored via the third PLA). X is a
  ## non-zero "window-2 only / invert" flag: `TXY` saves it, and when Y≠0 each
  ## expanded select byte is `AND #$AA` and WBGLOG/WOBJLOG are written as 0
  ## instead of `$5555`.
  ##
  ## Evidence (registers written):
  ## - long `$2123` W12SEL, `$2124` W34SEL, `$2125` WOBJSEL — each from the
  ##   expand table at `$C0B0A6` indexed by a 2-bit field of A.
  ## - long `$212E` TMW and `$212F` TSW — same `AND #$1F` byte.
  ## - long `$212A` (16-bit) WBGLOG+WOBJLOG — `$5555` or `$0000` by Y.
  ##
  ## Forces 8-bit A for the select packing, restores 16-bit A for the logic
  ## word, then RTL (does not PLP — entry flag width is not preserved beyond M).
  snesAsm(ConfigurePpuWindowsSnes, NativeFlags16):
    txy
    sep StatusM
    pha
    pha
    andOp WindowFieldMask
    tax
    lda longx WindowSelExpandTable
    cpy 0
    beq "w12Store"
    andOp Window2OnlyMask
    label "w12Store"
    sta long W12SelReg
    pla
    lsr a
    lsr a
    pha
    andOp WindowFieldMask
    tax
    lda longx WindowSelExpandTable
    cpy 0
    beq "w34Store"
    andOp Window2OnlyMask
    label "w34Store"
    sta long W34SelReg
    pla
    lsr a
    lsr a
    andOp WindowFieldMask
    tax
    lda longx WindowSelExpandTable
    cpy 0
    beq "wobjStore"
    andOp Window2OnlyMask
    label "wobjStore"
    sta long WobjSelReg
    pla
    andOp WindowMaskEnableBits
    sta long TmwReg
    sta long TswReg
    rep StatusM
    lda WindowLogicOrAll
    cpy 0
    beq "wlogStore"
    lda 0
    label "wlogStore"
    sta long WbgLogReg
    rtl

proc resetWindowPositions*(): seq[uint8] =
  ## Force WH0-WH3 to the open-edge pattern `$FF,$00,$FF,$00`.
  ##
  ## Entry (JSL): any M; forces 16-bit A. Writes long `$2126` (WH0+WH1) and
  ## long `$2128` (WH2+WH3) with `#$00FF` so each window pair spans the full
  ## horizontal range. Does not touch W*SEL / TMW / logic — only the position
  ## registers. Callers use this after `configurePpuWindows` (or alone) to
  ## clear leftover window geometry.
  snesAsm(ResetWindowPositionsSnes, NativeFlags16):
    rep StatusM
    lda WindowEdgesOpen
    sta long Wh0Reg
    sta long Wh2Reg
    rtl
