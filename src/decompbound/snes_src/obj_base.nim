## PPU object (sprite) base/size select — OBSEL helper
## (file 0x008D92 / SNES $C08D92).
##
## Sits between setBgMode ($C08D79) and setBg1Bases ($C08D9E) in the boot PPU
## setup chain. Writes OBSEL ($2101) from A and mirrors the byte into a WRAM
## shadow. ADOPTED into the region registry (adopted.nim); gold-gated by
## tests/test_regions.nim.

import
  ../snes_asm

const
  SetObjBaseOffset* = 0x008D92
  SetObjBaseSnes* = 0xC08D92'u32
  ## PPU: OBSEL — object (sprite) name base (bits 0-2), name select (3-4),
  ## and object size select (5-7).
  ObselReg* = 0x002101'u32
  ## WRAM shadow of OBSEL so game code can read the last written value.
  ObselShadow* = 0x000E'u32
  StatusM* = 0x20'u32

proc setObjBase*(): seq[uint8] =
  ## Write OBSEL ($2101) from A and mirror it to the WRAM shadow at $000E.
  ##
  ## Entry (JSL): any M; forces 8-bit A. Callers load A with the full OBSEL
  ## byte (name base + name select + size select) before the long call. Boot
  ## uses `LDA #$0062 / JSL $C08D92`. No field packing — the whole byte is
  ## stored to both `$000E` and long `$2101`.
  ##
  ## Not a DMA helper and not an OAM writer: only touches the object base/size
  ## select register. Sibling of setBgMode / setBgNBases in the PPU config family.
  snesAsm(SetObjBaseSnes, NativeFlags16):
    php
    sep StatusM
    sta abs ObselShadow
    sta long ObselReg
    plp
    rtl
