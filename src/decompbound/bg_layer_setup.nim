## PPU background layer setup — BGMODE / BGnSC / BGnNBA helpers
## (file 0x008D79 / SNES $C08D79 and siblings through $C08E5B).
##
## Boot and many scene transitions call these via JSL after loading A/X/Y with
## mode bits, tilemap VRAM word address, and character VRAM word address.
## They are NOT DMA or VRAM uploaders: every store targets a PPU configuration
## register ($2105 / $2107-$2109 / $210B-$210C) plus matching WRAM shadows.
## ADOPTED into the region registry (adopted.nim); gold-gated by
## tests/test_regions.nim.

import
  ./snes_asm

const
  SetBgModeOffset* = 0x008D79
  SetBgModeSnes* = 0xC08D79'u32
  SetBg1BasesOffset* = 0x008D9E
  SetBg1BasesSnes* = 0xC08D9E'u32
  SetBg2BasesOffset* = 0x008DDE
  SetBg2BasesSnes* = 0xC08DDE'u32
  SetBg3BasesOffset* = 0x008E1C
  SetBg3BasesSnes* = 0xC08E1C'u32
  ## PPU: BGMODE — screen mode (bits 0-2) and BG character sizes.
  BgModeReg* = 0x002105'u32
  ## PPU: BG1SC / BG2SC / BG3SC — tilemap base (bits 2-7, units of $400) and
  ## screen size (bits 0-1).
  Bg1ScReg* = 0x002107'u32
  Bg2ScReg* = 0x002108'u32
  Bg3ScReg* = 0x002109'u32
  ## PPU: BG12NBA — BG1 char base in low nibble, BG2 in high (units of $1000).
  Bg12NbaReg* = 0x00210B'u32
  ## PPU: BG34NBA — BG3 char base in low nibble, BG4 in high.
  Bg34NbaReg* = 0x00210C'u32
  ## WRAM shadows of the PPU regs above (mirrored so game code can read them).
  BgModeShadow* = 0x000F'u32
  Bg1ScShadow* = 0x0011'u32
  Bg2ScShadow* = 0x0012'u32
  Bg3ScShadow* = 0x0013'u32
  Bg12NbaShadow* = 0x0015'u32
  Bg34NbaShadow* = 0x0016'u32
  ## WRAM scroll shadows cleared when a BG layer is reconfigured (pairs are
  ## H then V). Consumers treat these as BG1/BG2/BG3 camera offsets.
  Bg1ScrollH* = 0x0031'u32
  Bg1ScrollV* = 0x0033'u32
  Bg2ScrollH* = 0x0035'u32
  Bg2ScrollV* = 0x0037'u32
  Bg3ScrollH* = 0x0039'u32
  Bg3ScrollV* = 0x003B'u32
  ## Masks for packing BGnSC / BGnNBA fields.
  BgScSizeMask* = 0x03'u32
  BgScBaseMask* = 0xFC'u32
  HighNibbleMask* = 0xF0'u32
  LowNibbleMask* = 0x0F'u32
  StatusM* = 0x20'u32
  StatusX* = 0x10'u32

proc setBgMode*(): seq[uint8] =
  ## Write BGMODE ($2105) from A, preserving the high nibble of the WRAM shadow.
  ##
  ## Entry (JSL): any M; forces 8-bit A. Callers typically `REP #$31` then
  ## `LDA #mode` (e.g. boot `$C00013` loads `#$0009`). The XBA stash keeps the
  ## mode byte while `$000F` is masked to its high nibble (`AND #$F0`); the
  ## mode is restored and OR'd in so bits 4-7 of the prior shadow survive.
  ## Result is stored to `$000F` and long-written to `$2105`.
  ##
  ## Not a DMA helper — only touches BGMODE. Sibling `$C08D92` (OBSEL / `$2101`)
  ## sits between this and setBg1Bases and is not adopted here.
  snesAsm(SetBgModeSnes, NativeFlags16):
    php
    sep StatusM
    xba
    lda abs BgModeShadow
    andOp HighNibbleMask
    sta abs BgModeShadow
    xba
    ora abs BgModeShadow
    sta abs BgModeShadow
    sta long BgModeReg
    plp
    rtl

proc setBg1Bases*(): seq[uint8] =
  ## Configure BG1 tilemap base/size ($2107) and BG1 character base ($210B lo).
  ##
  ## Entry (JSL): A = tilemap size bits 0-1 (masked with `#$03`); X = tilemap
  ## VRAM word address (high byte bits 2-7 become BG1SC base); Y = character
  ## VRAM word address (high byte >> 4 becomes BG12NBA low nibble). Forces
  ## 8-bit A / 16-bit X,Y.
  ##
  ## Evidence: `STA long $2107` after packing X/A into `$0011`; preserves the
  ## high nibble of `$0015` (BG2 char base) while writing the low nibble from
  ## Y, then `STA long $210B`. Also `STZ $0031` / `STZ $0033` (BG1 scroll
  ## shadows). Near-identical to setBg2Bases / setBg3Bases with different
  ## registers and nibble packing for the shared NBA byte.
  ##
  ## Boot call: `LDY #$0000 / LDX #$3800 / LDA #$0001 / JSL $C08D9E`.
  snesAsm(SetBg1BasesSnes, NativeFlags16):
    php
    sep StatusM
    rep StatusX
    andOp BgScSizeMask
    sta abs Bg1ScShadow
    rep StatusM
    txa
    xba
    sep StatusM
    andOp BgScBaseMask
    ora abs Bg1ScShadow
    sta abs Bg1ScShadow
    sta long Bg1ScReg
    lda abs Bg12NbaShadow
    andOp HighNibbleMask
    sta abs Bg12NbaShadow
    rep StatusM
    stz abs Bg1ScrollH
    stz abs Bg1ScrollV
    tya
    xba
    sep StatusM
    lsr a
    lsr a
    lsr a
    lsr a
    ora abs Bg12NbaShadow
    sta abs Bg12NbaShadow
    sta long Bg12NbaReg
    plp
    rtl

proc setBg2Bases*(): seq[uint8] =
  ## Configure BG2 tilemap base/size ($2108) and BG2 character base ($210B hi).
  ##
  ## Entry (JSL): same A/X/Y convention as setBg1Bases. Packs size+base into
  ## `$0012` / `$2108`. For BG12NBA, keeps the low nibble of `$0015` (BG1 char)
  ## and sets the high nibble from Y's high byte (`AND #$F0` — no 4× LSR,
  ## because BG2 already owns bits 4-7). Clears BG2 scroll shadows `$0035` /
  ## `$0037`.
  ##
  ## Boot call: `LDY #$2000 / LDX #$5800 / LDA #$0001 / JSL $C08DDE`.
  snesAsm(SetBg2BasesSnes, NativeFlags16):
    php
    sep StatusM
    rep StatusX
    andOp BgScSizeMask
    sta abs Bg2ScShadow
    rep StatusM
    txa
    xba
    sep StatusM
    andOp BgScBaseMask
    ora abs Bg2ScShadow
    sta abs Bg2ScShadow
    sta long Bg2ScReg
    lda abs Bg12NbaShadow
    andOp LowNibbleMask
    sta abs Bg12NbaShadow
    rep StatusM
    stz abs Bg2ScrollH
    stz abs Bg2ScrollV
    tya
    xba
    sep StatusM
    andOp HighNibbleMask
    ora abs Bg12NbaShadow
    sta abs Bg12NbaShadow
    sta long Bg12NbaReg
    plp
    rtl

proc setBg3Bases*(): seq[uint8] =
  ## Configure BG3 tilemap base/size ($2109) and BG3 character base ($210C lo).
  ##
  ## Entry (JSL): same A/X/Y convention as setBg1Bases. Writes `$0013` /
  ## `$2109` for the tilemap, and updates the low nibble of `$0016` /
  ## `$210C` (BG34NBA) from Y via 4× LSR — same packing as setBg1Bases but
  ## on the BG3/BG4 character-base register. Clears BG3 scroll shadows
  ## `$0039` / `$003B`. Sibling `$C08E5C` does the BG4 half and is not adopted.
  ##
  ## Boot call: `LDY #$6000 / LDX #$7C00 / LDA #$0000 / JSL $C08E1C`.
  snesAsm(SetBg3BasesSnes, NativeFlags16):
    php
    sep StatusM
    rep StatusX
    andOp BgScSizeMask
    sta abs Bg3ScShadow
    rep StatusM
    txa
    xba
    sep StatusM
    andOp BgScBaseMask
    ora abs Bg3ScShadow
    sta abs Bg3ScShadow
    sta long Bg3ScReg
    lda abs Bg34NbaShadow
    andOp HighNibbleMask
    sta abs Bg34NbaShadow
    rep StatusM
    stz abs Bg3ScrollH
    stz abs Bg3ScrollV
    tya
    xba
    sep StatusM
    lsr a
    lsr a
    lsr a
    lsr a
    ora abs Bg34NbaShadow
    sta abs Bg34NbaShadow
    sta long Bg34NbaReg
    plp
    rtl
