## PPU color-math helpers — CGWSEL / CGADSUB / COLDATA
## (file 0x00AFCD / SNES $C0AFCD and siblings through $C0B046).
##
## Small JSL-callable register writers used by scene / battle transitions to
## load a color-math preset, program the fixed color (COLDATA), or poke
## CGWSEL+CGADSUB directly. ADOPTED into the region registry (adopted.nim);
## gold-gated by tests/test_regions.nim.

import
  ../snes_asm

const
  ApplyColorMathPresetOffset* = 0x00AFCD
  ApplyColorMathPresetSnes* = 0xC0AFCD'u32
  SetFixedColorRgbOffset* = 0x00B01A
  SetFixedColorRgbSnes* = 0xC0B01A'u32
  WriteColorMathRegsOffset* = 0x00B039
  WriteColorMathRegsSnes* = 0xC0B039'u32
  ## PPU: CGWSEL — color-math enable / clip / fixed-vs-subscreen select.
  CgwselReg* = 0x002130'u32
  ## PPU: CGADSUB — add/sub mode and per-layer math enable mask.
  CgadsubReg* = 0x002131'u32
  ## PPU: COLDATA — fixed-color write; channel select in bits 5-7, intensity 0-4.
  ColdataReg* = 0x002132'u32
  ## WRAM shadows filled by the preset tables (main/sub screen designation
  ## style bytes — consumers read these; this routine does not STA $212C/$212D).
  ColorMathShadowA* = 0x001A'u32
  ColorMathShadowB* = 0x001B'u32
  ## ROM tables indexed by the preset number (A on entry → TAX).
  ## Four parallel 10/11-byte rows live at $C0AFF1 / $C0AFFC / $C0B006 / $C0B010
  ## (data, not adopted — only the loader is curated).
  PresetShadowATable* = 0xC0AFF1'u32
  PresetShadowBTable* = 0xC0AFFC'u32
  PresetCgwselTable* = 0xC0B006'u32
  PresetCgadsubTable* = 0xC0B010'u32
  ## COLDATA channel-select bits ORA'd onto the low 5 intensity bits.
  ColdataRedSelect* = 0x20'u32
  ColdataGreenSelect* = 0x40'u32
  ColdataBlueSelect* = 0x80'u32
  ColdataIntensityMask* = 0x1F'u32
  StatusM* = 0x20'u32

proc applyColorMathPreset*(): seq[uint8] =
  ## Load a color-math preset: shadows $001A/$001B plus CGWSEL/CGADSUB.
  ##
  ## Entry (JSL): 16-bit A holds the preset index (low byte used after TAX).
  ## Forces 8-bit A for the table loads, restores 16-bit A before RTL.
  ##
  ## Evidence: `TAX` then four `LDA longx $C0xxxx / STA ...` pairs write
  ## `$001A`, `$001B`, long `$2130` (CGWSEL), and long `$2131` (CGADSUB) from
  ## the parallel ROM tables immediately following this routine. Callers JSL
  ## with small constants (scene/battle color-math modes). Does not touch
  ## COLDATA — that is `setFixedColorRgb` next door.
  snesAsm(ApplyColorMathPresetSnes, NativeFlags16):
    tax
    sep StatusM
    lda longx PresetShadowATable
    sta abs ColorMathShadowA
    lda longx PresetShadowBTable
    sta abs ColorMathShadowB
    lda longx PresetCgwselTable
    sta long CgwselReg
    lda longx PresetCgadsubTable
    sta long CgadsubReg
    rep StatusM
    rtl

proc setFixedColorRgb*(): seq[uint8] =
  ## Program COLDATA ($2132) with separate R/G/B intensities from A/X/Y.
  ##
  ## Entry (JSL): any M; forces 8-bit A. A = red (0-31), X = green, Y = blue
  ## (low 5 bits used; high bits of each are masked off). Each component is
  ## ORA'd with its COLDATA channel-select bit and written write-once to
  ## `$2132` (hardware latches R, then G, then B on successive writes).
  ## Restores 16-bit A before RTL.
  ##
  ## Evidence: `AND #$1F / ORA #$20 / STA long $2132` then the same for X with
  ## `#$40` and Y with `#$80`. Sibling of `writeColorMathRegs` (CGWSEL/CGADSUB).
  snesAsm(SetFixedColorRgbSnes, NativeFlags16):
    sep StatusM
    andOp ColdataIntensityMask
    ora ColdataRedSelect
    sta long ColdataReg
    txa
    andOp ColdataIntensityMask
    ora ColdataGreenSelect
    sta long ColdataReg
    tya
    andOp ColdataIntensityMask
    ora ColdataBlueSelect
    sta long ColdataReg
    rep StatusM
    rtl

proc writeColorMathRegs*(): seq[uint8] =
  ## Write CGWSEL ($2130) from A and CGADSUB ($2131) from X.
  ##
  ## Entry (JSL): any M; forces 8-bit A. A = full CGWSEL byte, X = full
  ## CGADSUB byte. No field packing and no WRAM shadows — pure MMIO poke.
  ## Restores 16-bit A before RTL.
  ##
  ## Evidence: `STA long $2130 / TXA / STA long $2131`. Contrast
  ## `applyColorMathPreset`, which loads both from ROM tables and also fills
  ## `$001A`/`$001B`.
  snesAsm(WriteColorMathRegsSnes, NativeFlags16):
    sep StatusM
    sta long CgwselReg
    txa
    sta long CgadsubReg
    rep StatusM
    rtl
