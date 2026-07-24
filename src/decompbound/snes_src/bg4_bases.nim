## PPU BG4 tilemap/character base helper
## (file 0x008E5C / SNES $C08E5C).
##
## Completes the setBg1Bases / setBg2Bases / setBg3Bases family with the BG4
## half: BG4SC ($210A) plus the high nibble of BG34NBA ($210C). ADOPTED into
## the region registry (adopted.nim); gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  SetBg4BasesOffset* = 0x008E5C
  SetBg4BasesSnes* = 0xC08E5C'u32
  ## PPU: BG4SC — tilemap base (bits 2-7, units of $400) and screen size (0-1).
  Bg4ScReg* = 0x00210A'u32
  ## PPU: BG34NBA — BG3 char base in low nibble, BG4 in high (units of $1000).
  Bg34NbaReg* = 0x00210C'u32
  ## WRAM shadows of the PPU regs above.
  Bg4ScShadow* = 0x0014'u32
  Bg34NbaShadow* = 0x0016'u32
  ## WRAM scroll shadows cleared when BG4 is reconfigured (H then V).
  Bg4ScrollH* = 0x003D'u32
  Bg4ScrollV* = 0x003F'u32
  ## Masks for packing BGnSC / BGnNBA fields (same as bg_layer_setup.nim).
  BgScSizeMask* = 0x03'u32
  BgScBaseMask* = 0xFC'u32
  HighNibbleMask* = 0xF0'u32
  LowNibbleMask* = 0x0F'u32
  StatusM* = 0x20'u32
  StatusX* = 0x10'u32

proc setBg4Bases*(): seq[uint8] =
  ## Configure BG4 tilemap base/size ($210A) and BG4 character base ($210C hi).
  ##
  ## Entry (JSL): same A/X/Y convention as setBg1Bases / setBg3Bases. A =
  ## tilemap size bits 0-1 (masked with `#$03`); X = tilemap VRAM word address
  ## (high byte bits 2-7 become BG4SC base); Y = character VRAM word address
  ## (high byte becomes BG34NBA high nibble). Forces 8-bit A / 16-bit X,Y.
  ##
  ## Mirrors setBg3Bases on the opposite half of the shared registers:
  ## - Tilemap → `$0014` / `$210A` (BG4SC) instead of `$0013` / `$2109`.
  ## - Character base → high nibble of `$0016` / `$210C` (keeps BG3's low
  ##   nibble via `AND #$0F`, then `AND #$F0` on Y's high byte — same packing
  ##   as setBg2Bases, no 4× LSR, because BG4 already owns bits 4-7).
  ## - Clears BG4 scroll shadows `$003D` / `$003F`.
  snesAsm(SetBg4BasesSnes, NativeFlags16):
    php
    sep StatusM
    rep StatusX
    andOp BgScSizeMask
    sta abs Bg4ScShadow
    rep StatusM
    txa
    xba
    sep StatusM
    andOp BgScBaseMask
    ora abs Bg4ScShadow
    sta abs Bg4ScShadow
    sta long Bg4ScReg
    lda abs Bg34NbaShadow
    andOp LowNibbleMask
    sta abs Bg34NbaShadow
    rep StatusM
    stz abs Bg4ScrollH
    stz abs Bg4ScrollV
    tya
    xba
    sep StatusM
    andOp HighNibbleMask
    ora abs Bg34NbaShadow
    sta abs Bg34NbaShadow
    sta long Bg34NbaReg
    plp
    rtl
