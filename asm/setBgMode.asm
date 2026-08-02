; setBgMode
; Ported from snes_src/bg_layer_setup.nim :: setBgMode (evidence-preserving re-port).
;
; PPU background layer setup — BGMODE / BGnSC / BGnNBA helpers
; (file 0x008D79 / SNES $C08D79 and siblings through $C08E5B).
;
; Boot and many scene transitions call these via JSL after loading A/X/Y with
; mode bits, tilemap VRAM word address, and character VRAM word address.
; They are NOT DMA or VRAM uploaders: every store targets a PPU configuration
; register ($2105 / $2107-$2109 / $210B-$210C) plus matching WRAM shadows.
; ADOPTED into the region registry (adopted.nim); gold-gated by
; tests/test_regions.nim.
;
;
; --- setBgMode ---
; Write BGMODE ($2105) from A, preserving the high nibble of the WRAM shadow.
;
; Entry (JSL): any M; forces 8-bit A. Callers typically `REP #$31` then
; `LDA #mode` (e.g. boot `$C00013` loads `#$0009`). The XBA stash keeps the
; mode byte while `$000F` is masked to its high nibble (`AND #$F0`); the
; mode is restored and OR'd in so bits 4-7 of the prior shadow survive.
; Result is stored to `$000F` and long-written to `$2105`.
;
; Not a DMA helper — only touches BGMODE. Sibling `$C08D92` (OBSEL / `$2101`)
; sits between this and setBg1Bases and is not adopted here.
;
; Named constants (values inlined below; names preserved as comments):
;   SetBgModeOffset = $8D79
;   SetBgModeSnes = $C08D79
;   SetBg1BasesOffset = $8D9E
;   SetBg1BasesSnes = $C08D9E
;   SetBg2BasesOffset = $8DDE
;   SetBg2BasesSnes = $C08DDE
;   SetBg3BasesOffset = $8E1C
;   SetBg3BasesSnes = $C08E1C
;   BgModeReg = $2105
;     PPU: BGMODE — screen mode (bits 0-2) and BG character sizes.
;   Bg1ScReg = $2107
;     PPU: BG1SC / BG2SC / BG3SC — tilemap base (bits 2-7, units of $400) and
;     screen size (bits 0-1).
;   Bg2ScReg = $2108
;   Bg3ScReg = $2109
;   Bg12NbaReg = $210B
;     PPU: BG12NBA — BG1 char base in low nibble, BG2 in high (units of $1000).
;   Bg34NbaReg = $210C
;     PPU: BG34NBA — BG3 char base in low nibble, BG4 in high.
;   BgModeShadow = $0F
;     WRAM shadows of the PPU regs above (mirrored so game code can read them).
;   Bg1ScShadow = $11
;   Bg2ScShadow = $12
;   Bg3ScShadow = $13
;   Bg12NbaShadow = $15
;   Bg34NbaShadow = $16
;   Bg1ScrollH = $31
;     WRAM scroll shadows cleared when a BG layer is reconfigured (pairs are
;     H then V). Consumers treat these as BG1/BG2/BG3 camera offsets.
;   Bg1ScrollV = $33
;   Bg2ScrollH = $35
;   Bg2ScrollV = $37
;   Bg3ScrollH = $39
;   Bg3ScrollV = $3B
;   BgScSizeMask = $03
;     Masks for packing BGnSC / BGnNBA fields.
;   BgScBaseMask = $FC
;   HighNibbleMask = $F0
;   LowNibbleMask = $0F
;   StatusM = $20
;   StatusX = $10
;
.a16
.i16
PHP
SEP #$20  ; StatusM
.a8
.i16
XBA
LDA $000F  ; BgModeShadow — WRAM shadows of the PPU regs above (mirrored so game code can read them).
AND #$F0  ; HighNibbleMask
STA $000F  ; BgModeShadow — WRAM shadows of the PPU regs above (mirrored so game code can read them).
XBA
ORA $000F  ; BgModeShadow — WRAM shadows of the PPU regs above (mirrored so game code can read them).
STA $000F  ; BgModeShadow — WRAM shadows of the PPU regs above (mirrored so game code can read them).
STA $002105  ; BgModeReg — PPU: BGMODE — screen mode (bits 0-2) and BG character sizes.
PLP
RTL

